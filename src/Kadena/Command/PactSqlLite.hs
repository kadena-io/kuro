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


import qualified Data.Attoparsec.Text as AP

import Pact.Types
import Pact.Types.Orphans ()
import Pact.Native
import Pact.Compile
import Pact.Eval


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

data PSLState = PSLState {
      _txRecord :: M.Map Utf8 [TxLog]
    , _tableStmts :: M.Map Utf8 TableStmts
    , _txStmts :: TxStmts
    , _tmpSysCache :: SysCache
    , _sysCache :: SysCache
}
makeLenses ''PSLState

data PSLEnv = PSLEnv {
      conn :: Database
    , log :: forall s . Show s => (String -> s -> IO ())
}


psl :: PactDb PSLEnv PSLState
psl =
  PactDb {

   _readRow = \d k e s ->
       case d of
           KeySets -> return (HM.lookup (asString k) $ _cachedKeySets $ _tmpSysCache s,s)
           Modules -> return (HM.lookup (asString k) $ _cachedModules $ _tmpSysCache s,s)
           (UserTables t) -> (,s) <$> readRow' e s d (userTable t) k

 , _writeRow = \wt d k v e s ->
       case d of
           KeySets -> writeSys e s wt cachedKeySets keysetsTable k v
           Modules -> writeSys e s wt cachedModules modulesTable k v
           (UserTables t) -> writeUser e s wt t k v

 , _keys = \tn e s ->
       (fmap (,s) . mapM decodeText_) =<<
       qry_ e ("select key from " <> userTable tn <> " order by key") [RText]

 , _txids = \tn tid e s ->
       (fmap (,s) . mapM decodeInt_) =<<
       qry e ("select txid from " <> userTxRecord tn <> " where txid > ? order by txid")
               [SInt (fromIntegral tid)] [RInt]

 , _createUserTable = \tn mn ksn e s ->
       createUserTable' e s tn mn ksn

 , _getUserTableInfo = \tn e s ->
       log e "getUserTableInfo" tn >>
       case HM.lookup tn (_cachedTableInfo $ _tmpSysCache s) of
         Just r -> return (r,s)
         _ -> throwError $ "getUserTableInfo: no such table: " ++ show tn

 , _beginTx = \_ s ->
       execs_ (tBegin (_txStmts s)) >> return (resetTemp s)

 , _commitTx = \tid _ s -> do
       let tid' = SInt (fromIntegral tid)
           (PSLState trs stmts' txStmts' _ _) = s
           s' = s { _txRecord = M.empty, _sysCache = _tmpSysCache s }
       forM_ (M.toList trs) $ \(t,es) -> execs' (sRecordTx (stmts' M.! t)) [tid',sencode es]
       execs_ (tCommit txStmts')
       return ((),s')

 , _rollbackTx = \_ s ->
        execs_ (tRollback (_txStmts s)) >> return (resetTemp s)

 , _getTxLog = \d tid e s ->
      let tn :: Domain k v -> Utf8
          tn KeySets = keysetsTxRecord
          tn Modules = modulesTxRecord
          tn (UserTables t) = userTxRecord t
      in do
        r <- qry1 e ("select txlogs from " <> tn d <> " where txid = ?")
             [SInt (fromIntegral tid)] [RBlob]
        r' <- decodeBlob r
        return (r',s)


}




readRow' :: (AsString k,FromJSON v,Show k) => PSLEnv -> PSLState -> Domain k v -> Utf8 -> k -> IO (Maybe v)
readRow' e s _ t k = do
  log e "read" k
  r <- qrys e s t sRead [stext k] [RBlob]
  case r of
    [] -> return Nothing
    [a] -> Just <$> decodeBlob a
    _ -> throwError $ "read: more than one row found for table " ++ show t ++ ", key " ++ show k
{-# INLINE readRow' #-}

resetTemp :: PSLState -> ((),PSLState)
resetTemp s = ((),s { _txRecord = M.empty, _tmpSysCache = _sysCache s })

throwError :: String -> IO a
throwError s = throwM (userError s)

writeSys :: (AsString k,ToJSON v) => PSLEnv -> PSLState -> WriteType ->
            Setter' SysCache (HM.HashMap String v) -> Utf8 -> k -> v -> IO ((),PSLState)
writeSys _ s wt cache tbl k v =
    let q = case wt of
              Write -> sInsertReplace
              Insert -> sInsert
              Update -> sReplace
    in do
      execs s tbl q [stext k,sencode v]
      return $ ((),s { _tmpSysCache = over cache (HM.insert (asString k) v) (_tmpSysCache s) })
{-# INLINE writeSys #-}

writeUser :: PSLEnv -> PSLState -> WriteType -> TableName -> RowKey -> Columns Persistable -> IO ((),PSLState)
writeUser e s wt tn rk row = do
  log e "write" rk
  let ut = userTable tn
      rk' = stext rk
  olds <- qry e ("select value from " <> ut <> " where key = ?") [rk'] [RBlob]
  let ins = do
        let row' = sencode row
        execs s ut sInsert [rk',row']
        recordTx
      upd old = do
        oldrow <- decodeBlob old
        let row' = sencode (Columns (M.union (_columns row) (_columns oldrow)))
        execs s ut sReplace [rk',row']
        recordTx
      recordTx = return ((),s { _txRecord = M.insertWith (++) ut [TxLog (asString tn) (asString rk) (toJSON row)] $ _txRecord s } )
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

getTableStmts :: PSLState -> Utf8 -> TableStmts
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


withConn :: PSLEnv -> (Database -> IO a) -> IO a
withConn e f = f (conn e)

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


createUserTable' :: PSLEnv -> PSLState -> TableName -> ModuleName -> KeySetName -> IO ((),PSLState)
createUserTable' e s tn mn ksn = do
  exec' e "insert into usertables values (?,?,?)" [stext tn,stext mn,stext ksn]
  s' <- return $ over (tmpSysCache . cachedTableInfo) (HM.insert tn (mn,ksn)) s
  createTable e s' (userTable tn) (userTxRecord tn)

createTable :: PSLEnv -> PSLState -> Utf8 -> Utf8 -> IO ((),PSLState)
createTable e s ut ur = do
  exec_ e $ "create table " <> ut <>
              " (key text primary key not null unique, value SQLBlob) without rowid;"
  exec_ e $ "create table " <> ur <>
          " (txid integer primary key not null unique, txlogs SQLBlob);" -- 'without rowid' crashes!!
  c <- return (conn e)
  let mkstmt q = prepStmt c q
  ss <- TableStmts <$>
           mkstmt ("INSERT OR REPLACE INTO " <> ut <> " VALUES (?,?)") <*>
           mkstmt ("INSERT INTO " <> ut <> " VALUES (?,?)") <*>
           mkstmt ("REPLACE INTO " <> ut <> " VALUES (?,?)") <*>
           mkstmt ("select value from " <> ut <> " where key = ?") <*>
           mkstmt ("INSERT INTO " <> ur <> " VALUES (?,?)")
  return ((),over tableStmts (M.insert ut ss) s)


createSchema :: PSLEnv -> PSLState -> IO ((),PSLState)
createSchema e s = do
  exec_ e "CREATE TABLE IF NOT EXISTS usertables (\
    \ name TEXT PRIMARY KEY NOT NULL UNIQUE \
    \,module text NOT NULL \
    \,keyset text NOT NULL);"
  (_,s') <- createTable e s keysetsTable keysetsTxRecord
  createTable e s' modulesTable modulesTxRecord


exec_ :: PSLEnv -> Utf8 -> IO ()
exec_ e q = liftEither $ SQ3.exec (conn e) q
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

exec' :: PSLEnv -> Utf8 -> [SType] -> IO ()
exec' e q as = do
             stmt <- prepStmt (conn e) q
             bindParams stmt as
             r <- step stmt
             void $ finalize stmt
             void $ liftEither (return r)
{-# INLINE exec' #-}

execs :: PSLState -> Utf8 -> (TableStmts -> Statement) -> [SType] -> IO ()
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

prepStmt :: Database -> Utf8 -> IO Statement
prepStmt c q = do
    r <- prepare c q
    case r of
      Left e -> throwError (show e)
      Right Nothing -> throwError "Statement prep failed"
      Right (Just s) -> return s

qry :: PSLEnv -> Utf8 -> [SType] -> [RType] -> IO [[SType]]
qry e q as rts = do
  stmt <- prepStmt (conn e) q
  bindParams stmt as
  rows <- stepStmt stmt rts
  void $ finalize stmt
  return (reverse rows)
{-# INLINE qry #-}

qrys :: PSLEnv -> PSLState -> Utf8 -> (TableStmts -> Statement) -> [SType] -> [RType] -> IO [[SType]]
qrys _ s tn stmtf as rts = do
  stmt <- return $ stmtf $ getTableStmts s tn
  clearBindings stmt
  bindParams stmt as
  rows <- stepStmt stmt rts
  void $ reset stmt
  return (reverse rows)
{-# INLINE qrys #-}

qry_ :: PSLEnv -> Utf8 -> [RType] -> IO [[SType]]
qry_ e q rts = do
            stmt <- prepStmt (conn e) q
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


initState :: Database -> IO PSLState
initState c = (\ts -> PSLState M.empty M.empty ts def def) <$>
            (TxStmts <$> prepStmt c "BEGIN TRANSACTION"
                     <*> prepStmt c "COMMIT TRANSACTION"
                     <*> prepStmt c "ROLLBACK TRANSACTION")


qry1 :: PSLEnv -> Utf8 -> [SType] -> [RType] -> IO [SType]
qry1 e q as rts = do
  r <- qry e q as rts
  case r of
    [r'] -> return r'
    [] -> throwM $ userError "qry1: no results!"
    rs -> throwM $ userError $ "qry1: multiple results! (" ++ show (length rs) ++ ")"

runPragmas :: PSLEnv -> IO ()
runPragmas e = do
  exec_ e "PRAGMA synchronous = OFF"
  exec_ e "PRAGMA journal_mode = MEMORY"
  exec_ e "PRAGMA locking_mode = EXCLUSIVE"
  exec_ e "PRAGMA temp_store = MEMORY"


_run' :: (PSLEnv -> PSLState -> IO (a,PSLState)) -> IO (PSLEnv,(a,PSLState))
_run' a = do
  let f = "foo.sqllite"
  doesFileExist f >>= \b -> when b (removeFile f)
  c <- liftEither $ open (fromString f)
  let env = PSLEnv c (\m s -> putStrLn $ m ++ ": " ++ show s)
  s <- initState c
  r <- a env s
  return (env,r)

_run :: (PSLEnv -> PSLState -> IO (a,PSLState)) -> IO a
_run a = _run' a >>= \(PSLEnv e _,(r,_)) -> close e >> return r

beginTx' :: PSLEnv -> PSLState -> IO ()
beginTx' e s = void $ _beginTx psl e s
commitTx' :: TxId -> PSLEnv -> PSLState -> IO ()
commitTx' tid e s = void $ _commitTx psl tid e s

type PSLMethod a = Method PSLEnv PSLState a

writeRow' :: forall k v . (AsString k,ToJSON v) =>
                   WriteType -> Domain k v -> k -> v -> PSLMethod ()
writeRow' = _writeRow psl
readRow'' :: forall k v . (IsString k,FromJSON v) =>
                  Domain k v -> k -> PSLMethod (Maybe v)
readRow'' = _readRow psl

print' :: Show a => (a,b) -> IO ()
print' = print . fst

_test1 :: IO ()
_test1 =
    _run $ \e _s -> do
      t <- getCPUTime
      beginTx' e _s
      (_,_s) <- createSchema e _s
      (_,_s) <- createUserTable' e _s "stuff" "module" "keyset"
      print =<< qry_ e "select * from usertables" [RText,RText,RText]
      (_,_s) <- commit' e _s
      beginTx' e _s
      print' =<< _getUserTableInfo psl "stuff" e _s
      (_,_s) <- writeRow' Insert (UserTables "stuff") "key1"
               (Columns (M.fromList [("gah",PLiteral (LDecimal 123.454345))])) e _s
      print' =<< readRow'' (UserTables "stuff") "key1" e _s
      (_,_s) <- writeRow' Update (UserTables "stuff") "key1"
               (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)])) e _s
      print' =<< readRow'' (UserTables "stuff") "key1" e _s
      (_,_s) <- writeRow' Write KeySets "ks1"
               (PactKeySet [PublicKey "frah"] "stuff") e _s
      print' =<< readRow'' KeySets "ks1" e _s
      (_,_s) <- writeRow' Write Modules "mod1"
               (Module "mod1" "mod-admin-keyset" "code") e _s
      print' =<< readRow'' Modules "mod1" e _s
      _ <- commit' e _s
      (tids,_) <- _txids psl "stuff" (fromIntegral t) e _s
      print tids
      (print . fst) =<< _getTxLog psl (UserTables "stuff") (head tids) e _s
      return ((),_s)

commit' :: PSLMethod ()
commit' e s = getCPUTime >>= \t -> _commitTx psl (fromIntegral t) e s

_bench :: IO ()
_bench = do
  (el,(_,_s)) <- _run' $ \e _s -> do
      beginTx' e _s
      (_,_s) <- createSchema e _s
      (_,_s) <- _createUserTable psl "stuff" "module" "keyset" e _s
      commitTx' 123 e _s
      runPragmas e
      return ((),_s)
  e <- return $ nolog el
  benchmark $ whnfIO $ do
       beginTx' e _s
       (_,_s) <- writeRow' Write (UserTables "stuff") "key1"
                (Columns (M.fromList [("gah",PLiteral (LDecimal 123.454345))])) e _s
       _ <- readRow'' (UserTables "stuff") "key1" e _s
       (_,_s) <- writeRow' Update (UserTables "stuff") "key1"
                (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)])) e _s
       r <- readRow''  (UserTables "stuff") "key1" e _s
       void $ commit' e _s
       return r
  benchmark $ whnfIO $ do
       beginTx' e _s
       (_,_s) <- writeRow' Update (UserTables "stuff") "key1"
                (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)])) e _s
       commit' e _s

parseCompile :: T.Text -> [Term Name]
parseCompile code = compiled where
    (Right es) = AP.parseOnly exprs code
    (Right compiled) = mapM compile es

initEvalEnv :: e -> PactDb e s -> IO (EvalEnv e s)
initEvalEnv e b = do
  (Right nds,_) <- runEval undefined undefined nativeDefs
  return $ EvalEnv (RefStore nds HM.empty) def Null def def def e b

nolog :: PSLEnv -> PSLEnv
nolog e = e { log = \_ _ -> return () }

defState :: s -> EvalState s
defState s = EvalState def def def s

_pact :: IO ()
_pact = do
  void $ _run' $ \e _s -> do
      cf <- BS.readFile "demo/demo.pact"
      runPragmas e
      beginTx' e _s
      (_,_s) <- createSchema e _s
      (_,_s) <- commit' e _s
      let body = object ["keyset" A..= object ["keys" A..= ["demoadmin" :: T.Text], "pred" A..= (">" :: T.Text)]]
      evalEnv <- set eeMsgBody body <$> initEvalEnv e psl
      (r,es) <- runEval (defState _s) evalEnv $ do
          evalBeginTx
          rs <- mapM eval (parseCompile $ decodeUtf8 cf)
          evalCommitTx
          return rs
      _s <- return $ _evalPactDbState es
      print r
      print $ _sysCache _s
      ie <- return $ nolog e
      ieLog <- return e
      is <- return _s
      let evalEnv' = set eePactDbEnv ie $ over (eeRefStore.rsModules) (HM.union (HM.fromList (_rsNew (_evalRefs es)))) evalEnv

          pactBench pe benchterm = do
                                tid <- fromIntegral <$> getCPUTime
                                runEval (defState is) (set eePactDbEnv pe $ set eeTxId tid evalEnv') $ do
                                      evalBeginTx
                                      r' <- eval (head benchterm)
                                      evalCommitTx
                                      return r'
          pactSimple = runEval (defState is) evalEnv' . eval . head . parseCompile
          benchy n a = putStr n >> putStr " " >> benchmark (whnfIO $ a)
      -- benchy "(+ 1 2)" $ pactBench $ parseCompile "(+ 1 2)"
      -- benchy "(demo.app)" $ pactBench $ parseCompile "(demo.app)"
      print =<< pactBench ieLog (parseCompile "(demo.read-account \"Acct1\")")
      benchy "read-account simple" $ pactSimple $ "(demo.read-account \"Acct1\")"
      --benchy "read-accountc simple" $ pactSimple $ "(demo.read-accountc \"Acct1\")"
      benchy "read-account" $ pactBench ie $ parseCompile "(demo.read-account \"Acct1\")"
      benchy "PactSqlLite readRow in tx" $ do
                   beginTx' ie is
                   rr <- readRow'' (UserTables "demo-accounts") "Acct1" ie is
                   commit' ie is >> return rr
      void $ pactBench ieLog $ parseCompile "(demo.read-account \"Acct1\")"
      benchy "tableinfo" $ pactSimple "(describe-table 'demo-accounts)"
      void $ pactBench ieLog $ parseCompile "(demo.transfer \"Acct1\" \"Acct2\" 1.0)"
      benchy "transfer" $ pactBench ie $ parseCompile "(demo.transfer \"Acct1\" \"Acct2\" 1.0)"
      print' =<< readRow'' (UserTables "demo-accounts") "Acct1" ie is
      benchy "PactSqlLite readRow" $ runEval (defState is) evalEnv' $ readRow (UserTables "demo-accounts") "Acct1"
      benchy "getUserTableInfo" $ _getUserTableInfo psl "demo-accounts" ie is
      benchy "PactSqlLite writeRow in tx" $ do
                   beginTx' ie is
                   rr <- writeRow' Update (UserTables "demo-accounts") "Acct1"
                         (Columns (M.fromList [("balance",PLiteral (LDecimal 1000.0)),
                                               ("amount",PLiteral (LDecimal 1000.0)),
                                               ("data",PLiteral (LString "Admin account funding"))]))
                         ie is
                   commit' ie is >> return rr
      -- bench adds 5us for firing up monad stack.
      benchy "read-account" $ pactBench ie $ parseCompile "(demo.read-account \"Acct1\")"
      void $ pactBench ieLog $ parseCompile "(demo.fund-account \"Acct1\" 1000.0)"
      benchy "fund-account" $ pactBench ie $ parseCompile "(demo.fund-account \"Acct1\" 1000.0)"
      return ((),_s)
