{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE GADTs #-}
module Kadena.Command.PactSqlLite where

import Database.SQLite3.Direct as SQ3
import qualified Data.Text as T
import System.Directory
import Data.Monoid
import Control.Lens
import Data.String
import Data.Aeson hiding ((.=))
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import qualified Data.HashMap.Strict as HM
import Criterion hiding (env)
import Data.Text.Encoding
import Data.Int
import System.CPUTime
import Data.Default
import Prelude hiding (log)
import Control.Monad.Catch
import Control.Monad
import Control.Concurrent.MVar


import qualified Data.Attoparsec.Text as AP

import Pact.Types
import Pact.Types.Orphans ()
import Pact.Compile
import Pact.Eval
import Pact.Repl


data SType = SInt Int64 | SDouble Double | SText Utf8 | SBlob BS.ByteString deriving (Eq,Show)
data RType = RInt | RDouble | RText | RBlob deriving (Eq,Show)


data TableStmts = TableStmts {
      sInsertReplace :: Statement
    , sInsert :: Statement
    , sReplace :: Statement
    , sRead :: Statement
    , sRecordTx :: Statement
}

data TxStmts = TxStmts {
      tBegin :: Statement
    , tCommit :: Statement
    , tRollback :: Statement
}

data SysCache = SysCache {
      _cachedKeySets :: HM.HashMap String PactKeySet
    , _cachedModules :: HM.HashMap String Module
    , _cachedTableInfo :: HM.HashMap TableName (ModuleName,KeySetName)
} deriving (Show)

makeLenses ''SysCache
instance Default SysCache where def = SysCache HM.empty HM.empty HM.empty

data PSL = PSL {
      _conn :: Database
    , _log :: forall s . Show s => (String -> s -> IO ())
    , _txRecord :: M.Map Utf8 [TxLog]
    , _tableStmts :: M.Map Utf8 TableStmts
    , _txStmts :: TxStmts
    , _tmpSysCache :: SysCache
    , _sysCache :: SysCache
}
makeLenses ''PSL

psl :: PactDb PSL
psl =
  PactDb {

   _readRow = \d k e -> withMVar e $ \m ->
       case d of
           KeySets -> return $ HM.lookup (asString k) $ _cachedKeySets $ _tmpSysCache m
           Modules -> return $ HM.lookup (asString k) $ _cachedModules $ _tmpSysCache m
           (UserTables t) -> readRow' m d (userTable t) k

 , _writeRow = \wt d k v e ->
       case d of
           KeySets -> writeSys e wt cachedKeySets keysetsTable k v
           Modules -> writeSys e wt cachedModules modulesTable k v
           (UserTables t) -> writeUser e wt t k v

 , _keys = \tn e -> withMVar e $ \m ->
       mapM decodeText_ =<<
           qry_ m ("select key from " <> userTable tn <> " order by key") [RText]

 , _txids = \tn tid e -> withMVar e $ \m ->
       mapM decodeInt_ =<<
           qry m ("select txid from " <> userTxRecord tn <> " where txid > ? order by txid")
               [SInt (fromIntegral tid)] [RInt]

 , _createUserTable = \tn mn ksn e ->
       createUserTable' e tn mn ksn

 , _getUserTableInfo = \tn e -> withMVar e $ \m -> do
       _log m "getUserTableInfo" tn
       case HM.lookup tn (_cachedTableInfo $ _tmpSysCache m) of
         Just r -> return r
         _ -> throwError $ "getUserTableInfo: no such table: " ++ show tn

 , _beginTx = \s -> withMVar s resetTemp >>= \m -> execs_ (tBegin (_txStmts m))

 , _commitTx = \tid s -> modifyMVar_ s $ \m -> do
       let tid' = SInt (fromIntegral tid)
           m' = m { _txRecord = M.empty, _sysCache = _tmpSysCache m }
       forM_ (M.toList $ _txRecord m) $ \(t,es) -> execs' (sRecordTx (_tableStmts m M.! t)) [tid',sencode es]
       execs_ (tCommit $ _txStmts m)
       return m'

 , _rollbackTx = \s -> withMVar s resetTemp >>= \m -> execs_ (tRollback (_txStmts m))

 , _getTxLog = \d tid e -> withMVar e $ \m -> do
      let tn :: Domain k v -> Utf8
          tn KeySets = keysetsTxRecord
          tn Modules = modulesTxRecord
          tn (UserTables t) = userTxRecord t
      r <- qry1 m ("select txlogs from " <> tn d <> " where txid = ?")
                     [SInt (fromIntegral tid)] [RBlob]
      decodeBlob r

}




readRow' :: (AsString k,FromJSON v,Show k) => PSL -> Domain k v -> Utf8 -> k -> IO (Maybe v)
readRow' m _ t k = do
  _log m "read" k
  r <- qrys m t sRead [stext k] [RBlob]
  case r of
    [] -> return Nothing
    [a] -> Just <$> decodeBlob a
    _ -> throwError $ "read: more than one row found for table " ++ show t ++ ", key " ++ show k
{-# INLINE readRow' #-}

resetTemp :: PSL -> IO PSL
resetTemp s = return $ s { _txRecord = M.empty, _tmpSysCache = _sysCache s }

throwError :: String -> IO a
throwError s = throwM (userError s)

writeSys :: (AsString k,ToJSON v) => MVar PSL -> WriteType ->
            Setter' SysCache (HM.HashMap String v) -> Utf8 -> k -> v -> IO ()
writeSys s wt cache tbl k v = modifyMVar_ s $ \m -> do
    let q = case wt of
              Write -> sInsertReplace
              Insert -> sInsert
              Update -> sReplace
    execs m tbl q [stext k,sencode v]
    return $ m { _tmpSysCache = over cache (HM.insert (asString k) v) (_tmpSysCache m) }
{-# INLINE writeSys #-}

writeUser :: MVar PSL -> WriteType -> TableName -> RowKey -> Columns Persistable -> IO ()
writeUser s wt tn rk row = modifyMVar_ s $ \m -> do
  _log m "write" rk
  let ut = userTable tn
      rk' = stext rk
  olds <- qry m ("select value from " <> ut <> " where key = ?") [rk'] [RBlob]
  let ins = do
        let row' = sencode row
        execs m ut sInsert [rk',row']
        recordTx
      upd old = do
        oldrow <- decodeBlob old
        let row' = sencode (Columns (M.union (_columns row) (_columns oldrow)))
        execs m ut sReplace [rk',row']
        recordTx
      recordTx = return $
                 m { _txRecord = M.insertWith (++) ut [TxLog (asString tn) (asString rk) (toJSON row)] $ _txRecord m }
  case (olds,wt) of
    ([],Insert) -> ins
    (_,Insert) -> throwError $ "Insert: row found for key " ++ show rk
    ([],Write) -> ins
    ([old],Write) -> upd old
    (_,Write) -> throwError $ "Write: more than one row found for key " ++ show rk
    ([old],Update) -> upd old
    ([],Update) -> throwError $ "Update: no row found for key " ++ show rk
    (_,Update) -> throwError $ "Update: more than one row found for key " ++ show rk
{-# INLINE writeUser #-}

getTableStmts :: PSL -> Utf8 -> TableStmts
getTableStmts s tn = (M.! tn) . _tableStmts $ s

decodeBlob :: (FromJSON v) => [SType] -> IO v
decodeBlob [SBlob old] = liftEither (return $ eitherDecodeStrict' old)
decodeBlob v = throwError $ "Expected single-column blob, got: " ++ show v
{-# INLINE decodeBlob #-}

decodeInt_ :: (Integral v) => [SType] -> IO v
decodeInt_ [SInt i] = return $ fromIntegral $ i
decodeInt_ v = throwError $ "Expected single-column int, got: " ++ show v
{-# INLINE decodeInt_ #-}

decodeText :: (IsString v) => SType -> IO v
decodeText (SText (Utf8 t)) = return $ fromString $ T.unpack $ decodeUtf8 t
decodeText v = throwError $ "Expected text, got: " ++ show v
{-# INLINE decodeText #-}

decodeText_ :: (IsString v) => [SType] -> IO v
decodeText_ [SText (Utf8 t)] = return $ fromString $ T.unpack $ decodeUtf8 t
decodeText_ v = throwError $ "Expected single-column text, got: " ++ show v
{-# INLINE decodeText_ #-}


userTable :: TableName -> Utf8
userTable tn = "UTBL_" <> (Utf8 $ encodeUtf8 $ sanitize tn)
{-# INLINE userTable #-}
userTxRecord :: TableName -> Utf8
userTxRecord tn = "UTXR_" <> (Utf8 $ encodeUtf8 $ sanitize tn)
{-# INLINE userTxRecord #-}
sanitize :: AsString t => t -> T.Text
sanitize tn = T.replace "-" "_" $ T.pack (asString tn)
{-# INLINE sanitize #-}

keysetsTable :: Utf8
keysetsTable = "STBL_keysets"
modulesTable :: Utf8
modulesTable = "STBL_modules"
keysetsTxRecord :: Utf8
keysetsTxRecord = "STXR_keysets"
modulesTxRecord :: Utf8
modulesTxRecord = "STXR_modules"

sencode :: ToJSON a => a -> SType
sencode a = SBlob $ BSL.toStrict $ encode a
{-# INLINE sencode #-}

stext :: AsString a => a -> SType
stext a = SText $ fromString $ asString a
{-# INLINE stext #-}


createUserTable' :: MVar PSL -> TableName -> ModuleName -> KeySetName -> IO ()
createUserTable' s tn mn ksn = modifyMVar_ s $ \m -> do
  exec' m "insert into usertables values (?,?,?)" [stext tn,stext mn,stext ksn]
  m' <- return $ over (tmpSysCache . cachedTableInfo) (HM.insert tn (mn,ksn)) m
  createTable (userTable tn) (userTxRecord tn) m'

createTable :: Utf8 -> Utf8 -> PSL -> IO PSL
createTable ut ur e = do
  exec_ e $ "create table " <> ut <>
              " (key text primary key not null unique, value SQLBlob) without rowid;"
  exec_ e $ "create table " <> ur <>
          " (txid integer primary key not null unique, txlogs SQLBlob);" -- 'without rowid' crashes!!
  let mkstmt q = prepStmt e q
  ss <- TableStmts <$>
           mkstmt ("INSERT OR REPLACE INTO " <> ut <> " VALUES (?,?)") <*>
           mkstmt ("INSERT INTO " <> ut <> " VALUES (?,?)") <*>
           mkstmt ("REPLACE INTO " <> ut <> " VALUES (?,?)") <*>
           mkstmt ("select value from " <> ut <> " where key = ?") <*>
           mkstmt ("INSERT INTO " <> ur <> " VALUES (?,?)")
  return (over tableStmts (M.insert ut ss) e)


createSchema :: PSL -> IO PSL
createSchema s = do
  exec_ s "CREATE TABLE IF NOT EXISTS usertables (\
    \ name TEXT PRIMARY KEY NOT NULL UNIQUE \
    \,module text NOT NULL \
    \,keyset text NOT NULL);"
  createTable keysetsTable keysetsTxRecord s >>= createTable modulesTable modulesTxRecord


exec_ :: PSL -> Utf8 -> IO ()
exec_ e q = liftEither $ SQ3.exec (_conn e) q
{-# INLINE exec_ #-}

execs_ :: Statement -> IO ()
execs_ s = do
  r <- step s
  void $ reset s
  void $ liftEither (return r)
{-# INLINE execs_ #-}

liftEither :: Show a => IO (Either a b) -> IO b
liftEither a = do
  er <- a
  case er of
    (Left e) -> throwError (show e)
    (Right r) -> return r
{-# INLINE liftEither #-}

exec' :: PSL -> Utf8 -> [SType] -> IO ()
exec' e q as = do
             stmt <- prepStmt e q
             bindParams stmt as
             r <- step stmt
             void $ finalize stmt
             void $ liftEither (return r)
{-# INLINE exec' #-}

execs :: PSL -> Utf8 -> (TableStmts -> Statement) -> [SType] -> IO ()
execs s tn stmtf as = do
  stmt <- return $ stmtf $ getTableStmts s tn
  execs' stmt as
{-# INLINE execs #-}

execs' :: Statement -> [SType] -> IO ()
execs' stmt as = do
    clearBindings stmt
    bindParams stmt as
    r <- step stmt
    void $ reset stmt
    void $ liftEither (return r)
{-# INLINE execs' #-}


bindParams :: Statement -> [SType] -> IO ()
bindParams stmt as =
    void $ liftEither
    (sequence <$> forM (zip as [1..]) ( \(a,i) -> do
      case a of
        SInt n -> bindInt64 stmt i n
        SDouble n -> bindDouble stmt i n
        SText n -> bindText stmt i n
        SBlob n -> bindBlob stmt i n))
{-# INLINE bindParams #-}

prepStmt :: PSL -> Utf8 -> IO Statement
prepStmt c q = prepStmt' (_conn c) q

prepStmt' :: Database -> Utf8 -> IO Statement
prepStmt' c q = do
    r <- prepare c q
    case r of
      Left e -> throwError (show e)
      Right Nothing -> throwError "Statement prep failed"
      Right (Just s) -> return s

qry :: PSL -> Utf8 -> [SType] -> [RType] -> IO [[SType]]
qry e q as rts = do
  stmt <- prepStmt e q
  bindParams stmt as
  rows <- stepStmt stmt rts
  void $ finalize stmt
  return (reverse rows)
{-# INLINE qry #-}

qrys :: PSL -> Utf8 -> (TableStmts -> Statement) -> [SType] -> [RType] -> IO [[SType]]
qrys s tn stmtf as rts = do
  stmt <- return $ stmtf $ getTableStmts s tn
  clearBindings stmt
  bindParams stmt as
  rows <- stepStmt stmt rts
  void $ reset stmt
  return (reverse rows)
{-# INLINE qrys #-}

qry_ :: PSL -> Utf8 -> [RType] -> IO [[SType]]
qry_ e q rts = do
            stmt <- prepStmt e q
            rows <- stepStmt stmt rts
            _ <- finalize stmt
            return (reverse rows)
{-# INLINE qry_ #-}

stepStmt :: Statement -> [RType] -> IO [[SType]]
stepStmt stmt rts = do
  let acc rs Done = return rs
      acc rs Row = do
        as <- forM (zip rts [0..]) $ \(rt,ci) -> do
                      case rt of
                        RInt -> SInt <$> columnInt64 stmt ci
                        RDouble -> SDouble <$> columnDouble stmt ci
                        RText -> SText <$> columnText stmt ci
                        RBlob -> SBlob <$> columnBlob stmt ci
        sr <- liftEither $ step stmt
        acc (as:rs) sr
  sr <- liftEither $ step stmt
  acc [] sr
{-# INLINE stepStmt #-}


initState :: FilePath -> IO PSL
initState f = do
  c <- liftEither $ open (fromString f)
  ts <- TxStmts <$> prepStmt' c "BEGIN TRANSACTION"
         <*> prepStmt' c "COMMIT TRANSACTION"
         <*> prepStmt' c "ROLLBACK TRANSACTION"
  s <- return $ PSL c (\m s -> putStrLn $ m ++ ": " ++ show s) M.empty M.empty ts def def
  runPragmas s
  return s



qry1 :: PSL -> Utf8 -> [SType] -> [RType] -> IO [SType]
qry1 e q as rts = do
  r <- qry e q as rts
  case r of
    [r'] -> return r'
    [] -> throwM $ userError "qry1: no results!"
    rs -> throwM $ userError $ "qry1: multiple results! (" ++ show (length rs) ++ ")"

runPragmas :: PSL -> IO ()
runPragmas e = do
  exec_ e "PRAGMA synchronous = OFF"
  exec_ e "PRAGMA journal_mode = MEMORY"
  exec_ e "PRAGMA locking_mode = EXCLUSIVE"
  exec_ e "PRAGMA temp_store = MEMORY"


_initPSL :: IO PSL
_initPSL = do
  let f = "foo.sqllite"
  doesFileExist f >>= \b -> when b (removeFile f)
  initState f

_run :: (MVar PSL -> IO ()) -> IO ()
_run a = do
  m <- _initPSL
  s <- newMVar m
  a s
  void $ close (_conn m)



_test1 :: IO ()
_test1 =
    _run $ \e -> do
      t <- getCPUTime
      _beginTx psl e
      modifyMVar_ e createSchema
      createUserTable' e "stuff" "module" "keyset"
      withMVar e $ \m -> qry_ m "select * from usertables" [RText,RText,RText] >>= print
      void $ commit' e
      _beginTx psl e
      print =<< _getUserTableInfo psl "stuff" e
      _writeRow psl Insert (UserTables "stuff") "key1"
               (Columns (M.fromList [("gah",PLiteral (LDecimal 123.454345))])) e
      print =<< _readRow psl (UserTables "stuff") "key1" e
      _writeRow psl Update (UserTables "stuff") "key1"
               (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)])) e
      print =<< _readRow psl (UserTables "stuff") "key1" e
      _writeRow psl Write KeySets "ks1"
               (PactKeySet [PublicKey "frah"] "stuff") e
      print =<< _readRow psl KeySets "ks1" e
      _writeRow psl Write Modules "mod1"
               (Module "mod1" "mod-admin-keyset" "code") e
      print =<< _readRow psl Modules "mod1" e
      void $ commit' e
      tids <- _txids psl "stuff" (fromIntegral t) e
      print tids
      print =<< _getTxLog psl (UserTables "stuff") (head tids) e


commit' :: MVar PSL -> IO TxId
commit' e = do
  t <- fromIntegral <$> getCPUTime
  _commitTx psl t e
  return t



_bench :: IO ()
_bench = _run $ \e -> do
  _beginTx psl e
  modifyMVar_ e createSchema
  _createUserTable psl "stuff" "module" "keyset" e
  void $ commit' e
  nolog e
  benchmark $ whnfIO $ do
       _beginTx psl e
       _writeRow psl Write (UserTables "stuff") "key1"
                (Columns (M.fromList [("gah",PLiteral (LDecimal 123.454345))])) e
       void $ _readRow psl (UserTables "stuff") "key1" e
       _writeRow psl Update (UserTables "stuff") "key1"
                (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)])) e
       r <- _readRow psl  (UserTables "stuff") "key1" e
       void $ commit' e
       return r
  benchmark $ whnfIO $ do
       _beginTx psl e
       _writeRow psl Update (UserTables "stuff") "key1"
                (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)])) e
       commit' e

nolog :: MVar PSL -> IO ()
nolog e = modifyMVar_ e $ \m -> return $ m { _log = \_ _ -> return () }


parseCompile :: T.Text -> [Term Name]
parseCompile code = compiled where
    (Right es) = AP.parseOnly exprs code
    (Right compiled) = mapM compile es


_pact :: Bool -> IO ()
_pact doBench = do
      m <- _initPSL
      let body = object ["keyset" A..= object ["keys" A..= ["demoadmin" :: T.Text], "pred" A..= (">" :: T.Text)]]
      evalEnv <- set eeMsgBody body <$> initEvalEnv m psl
      e <- return (_eePactDbVar evalEnv)
      cf <- BS.readFile "demo/demo.pact"
      _beginTx psl e
      modifyMVar_ e createSchema
      void $ commit' e
      (r,es) <- runEval def evalEnv $ do
          evalBeginTx
          rs <- mapM eval (parseCompile $ decodeUtf8 cf)
          evalCommitTx
          return rs
      print r
      let evalEnv' = over (eeRefStore.rsModules) (HM.union (HM.fromList (_rsNew (_evalRefs es)))) evalEnv
          pactBench benchterm = do
                                tid <- fromIntegral <$> getCPUTime
                                runEval def (set eeTxId tid evalEnv') $ do
                                      evalBeginTx
                                      r' <- eval (head benchterm)
                                      evalCommitTx
                                      return r'
          pactSimple = runEval def evalEnv' . eval . head . parseCompile
          benchy n a = putStr n >> putStr " " >> benchmark (whnfIO $ a)
      when doBench $ nolog e
      print =<< pactBench (parseCompile "(demo.read-account \"Acct1\")")
      benchy "read-account simple" $ pactSimple $ "(demo.read-account \"Acct1\")"
      --benchy "read-accountc simple" $ pactSimple $ "(demo.read-accountc \"Acct1\")"
      benchy "read-account" $ pactBench $ parseCompile "(demo.read-account \"Acct1\")"
      benchy "PactSqlLite readRow in tx" $ do
                   _beginTx psl e
                   rr <- _readRow psl (UserTables "demo-accounts") "Acct1" e
                   void $ commit' e
                   return rr
      print =<< pactBench (parseCompile "(demo.read-account \"Acct1\")")
      benchy "tableinfo" $ pactSimple "(describe-table 'demo-accounts)"
      print =<< pactBench (parseCompile "(demo.transfer \"Acct1\" \"Acct2\" 1.0)")
      benchy "transfer" $ pactBench  $ parseCompile "(demo.transfer \"Acct1\" \"Acct2\" 1.0)"
      print =<< _readRow psl (UserTables "demo-accounts") "Acct1" e
      benchy "PactSqlLite readRow" $ runEval def evalEnv' $ readRow (UserTables "demo-accounts") "Acct1"
      benchy "getUserTableInfo" $ _getUserTableInfo psl "demo-accounts" e
      benchy "PactSqlLite writeRow in tx" $ do
                   _beginTx psl e
                   rr <- _writeRow psl Update (UserTables "demo-accounts") "Acct1"
                         (Columns (M.fromList [("balance",PLiteral (LDecimal 1000.0)),
                                               ("amount",PLiteral (LDecimal 1000.0)),
                                               ("data",PLiteral (LString "Admin account funding"))]))
                         e
                   void $ commit' e
                   return rr
      -- bench adds 5us for firing up monad stack.
      benchy "read-account" $ pactBench $ parseCompile "(demo.read-account \"Acct1\")"
      void $ pactBench $ parseCompile "(demo.fund-account \"Acct1\" 1000.0)"
      benchy "fund-account" $ pactBench $ parseCompile "(demo.fund-account \"Acct1\" 1000.0)"
