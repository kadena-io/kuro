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

import Control.Monad.Reader
import Control.Monad.Catch
import Control.Monad.State.Strict
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

data PSLState = PSLState {
      _txRecord :: M.Map Utf8 [TxLog]
    , _tableStmts :: M.Map Utf8 TableStmts
    , _txStmts :: TxStmts
}
makeLenses ''PSLState

instance FromJSON TxLog where
    parseJSON = withObject "TxLog" $ \o ->
                TxLog <$> o .: "table" <*> o .: "key" <*> o .: "value"

data PSLEnv = PSLEnv {
      conn :: Database
}

newtype PactSqlLite a = PactSqlLite { runPSL :: StateT PSLState (ReaderT PSLEnv IO) a }
    deriving (Functor,Applicative,Monad,MonadReader PSLEnv,MonadCatch,MonadThrow,MonadIO,MonadState PSLState)

instance MonadPact PactSqlLite where

    -- readRow :: Domain d k v -> k -> m (Maybe v)
    readRow KeySets k = readRow' KeySets keysetsTable k
    readRow Modules k = readRow' Modules modulesTable k
    readRow d@(UserTables t) k = readRow' d (userTable t) k


    -- writeRow :: WriteType -> Domain d k v -> k -> v -> m ()
    writeRow wt KeySets k v = writeSys wt keysetsTable k v
    writeRow wt Modules k v = writeSys wt modulesTable k v
    writeRow wt (UserTables t) k v = writeUser wt t k v



    -- keys :: TableName -> m [RowKey]
    keys tn = mapM decodeText_ =<< qry_ ("select key from " <> userTable tn <> " order by key") [RText]


    -- txids :: TableName -> TxId -> m [TxId]
    txids tn tid = mapM decodeInt_ =<<
                   qry ("select txid from " <> userTxRecord tn <> " where txid > ? order by txid")
                   [SInt (fromIntegral tid)] [RInt]



    -- createUserTable :: TableName -> ModuleName -> KeySetName -> m ()
    createUserTable tn mn ksn = createUserTable' tn mn ksn


    -- getUserTableInfo :: TableName -> m (ModuleName,KeySetName)
    getUserTableInfo tn = do
      [m,k] <- qry1 "select module, keyset from usertables where name=?" [stext tn] [RText,RText]
      (,) <$> decodeText m <*> decodeText k

    -- beginTx :: m ()
    beginTx = resetTemp >>= \s -> execs_ (tBegin (_txStmts s))


    -- commitTx :: TxId -> m ()
    commitTx tid = do
      let tid' = SInt (fromIntegral tid)
      (PSLState trs stmts' txStmts') <- state (\s -> (s,s { _txRecord = M.empty }))
      forM_ (M.toList trs) $ \(t,es) -> execs' (sRecordTx (stmts' M.! t)) [tid',sencode es]
      execs_ (tCommit txStmts')


    -- rollbackTx :: m ()
    rollbackTx = resetTemp >>= \s -> execs_ (tRollback (_txStmts s))

    -- getTxLog :: Domain d k v -> TxId -> m [TxLog]
    getTxLog d tid =
        let tn :: Domain d k v -> Utf8
            tn KeySets = keysetsTxRecord
            tn Modules = modulesTxRecord
            tn (UserTables t) = userTxRecord t
        in decodeBlob =<<
           qry1 ("select txlogs from " <> tn d <> " where txid = ?")
                   [SInt (fromIntegral tid)] [RBlob]


    {-# INLINE readRow #-}
    {-# INLINE writeRow #-}
    {-# INLINE createUserTable #-}
    {-# INLINE getUserTableInfo #-}
    {-# INLINE commitTx #-}
    {-# INLINE beginTx #-}
    {-# INLINE rollbackTx #-}
    {-# INLINE getTxLog #-}
    {-# INLINE keys #-}
    {-# INLINE txids #-}



readRow' :: (AsString k,FromJSON v,Show k) => Domain d k v -> Utf8 -> k -> PactSqlLite (Maybe v)
readRow' _ t k = do
  r <- qrys t sRead [stext k] [RBlob]
  case r of
    [] -> return Nothing
    [a] -> Just <$> decodeBlob a
    _ -> throwError $ "read: more than one row found for table " ++ show t ++ ", key " ++ show k
{-# INLINE readRow' #-}

resetTemp :: PactSqlLite PSLState
resetTemp = state (\s -> (s,s { _txRecord = M.empty }))

throwError :: MonadThrow m => String -> m a
throwError s = throwM (userError s)

writeSys :: (AsString k,ToJSON v) => WriteType -> Utf8 -> k -> v -> PactSqlLite ()
writeSys wt tbl k v =
    let q = case wt of
              Write -> sInsertReplace
              Insert -> sInsert
              Update -> sReplace
    in execs tbl q [stext k,sencode v]
{-# INLINE writeSys #-}

writeUser :: WriteType -> TableName -> RowKey -> Columns Persistable -> PactSqlLite ()
writeUser wt tn rk row = do
  let ut = userTable tn
      rk' = stext rk
  olds <- qry ("select value from " <> ut <> " where key = ?") [rk'] [RBlob]
  let ins = do
        let row' = sencode row
        execs ut sInsert [rk',row']
        recordTx
      upd old = do
        oldrow <- decodeBlob old
        let row' = sencode (Columns (M.union (_columns row) (_columns oldrow)))
        execs ut sReplace [rk',row']
        recordTx
      recordTx = modify (\s -> s { _txRecord = M.insertWith (++) ut [TxLog (asString tn) (asString rk) (toJSON row)] $ _txRecord s } )
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

getTableStmts :: Utf8 -> PactSqlLite TableStmts
getTableStmts tn = (M.! tn) . _tableStmts <$> get

decodeBlob :: (FromJSON v) => [SType] -> PactSqlLite v
decodeBlob [SBlob old] = liftEither (return $ eitherDecodeStrict' old)
decodeBlob v = throwError $ "Expected single-column blob, got: " ++ show v
{-# INLINE decodeBlob #-}

decodeInt_ :: (Integral v) => [SType] -> PactSqlLite v
decodeInt_ [SInt i] = return $ fromIntegral $ i
decodeInt_ v = throwError $ "Expected single-column int, got: " ++ show v
{-# INLINE decodeInt_ #-}

decodeText :: (IsString v) => SType -> PactSqlLite v
decodeText (SText (Utf8 t)) = return $ fromString $ T.unpack $ decodeUtf8 t
decodeText v = throwError $ "Expected text, got: " ++ show v
{-# INLINE decodeText #-}

decodeText_ :: (IsString v) => [SType] -> PactSqlLite v
decodeText_ [SText (Utf8 t)] = return $ fromString $ T.unpack $ decodeUtf8 t
decodeText_ v = throwError $ "Expected single-column text, got: " ++ show v
{-# INLINE decodeText_ #-}


withConn :: (Database -> PactSqlLite a) -> PactSqlLite a
withConn f = reader conn >>= \c -> f c

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


createUserTable' :: TableName -> ModuleName -> KeySetName -> PactSqlLite ()
createUserTable' tn mn ksn = do
  exec' "insert into usertables values (?,?,?)" [stext tn,stext mn,stext ksn]
  createTable (userTable tn) (userTxRecord tn)

createTable :: Utf8 -> Utf8 -> PactSqlLite ()
createTable ut ur = do
  exec_ $ "create table " <> ut <>
              " (key text primary key not null unique, value SQLBlob) without rowid;"
  exec_ $ "create table " <> ur <>
          " (txid integer primary key not null unique, txlogs SQLBlob);" -- 'without rowid' crashes!!
  c <- reader conn
  let mkstmt q = liftIO $ prepStmt c q
  ss <- TableStmts <$>
           mkstmt ("INSERT OR REPLACE INTO " <> ut <> " VALUES (?,?)") <*>
           mkstmt ("INSERT INTO " <> ut <> " VALUES (?,?)") <*>
           mkstmt ("REPLACE INTO " <> ut <> " VALUES (?,?)") <*>
           mkstmt ("select value from " <> ut <> " where key = ?") <*>
           mkstmt ("INSERT INTO " <> ur <> " VALUES (?,?)")
  tableStmts %= M.insert ut ss


createSchema :: PactSqlLite ()
createSchema = do
  exec_ "CREATE TABLE IF NOT EXISTS usertables (\
    \ name TEXT PRIMARY KEY NOT NULL UNIQUE \
    \,module text NOT NULL \
    \,keyset text NOT NULL);"
  createTable keysetsTable keysetsTxRecord
  createTable modulesTable modulesTxRecord


exec_ :: Utf8 -> PactSqlLite ()
exec_ q = withConn $ \c -> liftIO $ liftEither $ SQ3.exec c q
{-# INLINE exec_ #-}

execs_ :: Statement -> PactSqlLite ()
execs_ s = liftIO $ do
             r <- step s
             void $ reset s
             void $ liftEither (return r)
{-# INLINE execs_ #-}

liftEither :: (Show a, MonadThrow m) => m (Either a b) -> m b
liftEither a = do
  er <- a
  case er of
    (Left e) -> throwError (show e)
    (Right r) -> return r
{-# INLINE liftEither #-}

exec' :: Utf8 -> [SType] -> PactSqlLite ()
exec' q as = withConn $ \c -> liftIO $ do
             stmt <- prepStmt c q
             bindParams stmt as
             r <- step stmt
             void $ finalize stmt
             void $ liftEither (return r)
{-# INLINE exec' #-}

execs :: Utf8 -> (TableStmts -> Statement) -> [SType] -> PactSqlLite ()
execs tn stmtf as = do
  stmt <- stmtf <$> getTableStmts tn
  execs' stmt as
{-# INLINE execs #-}

execs' :: Statement -> [SType] -> PactSqlLite ()
execs' stmt as = liftIO $ do
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

qry :: Utf8 -> [SType] -> [RType] -> PactSqlLite [[SType]]
qry q as rts = withConn $ \c -> liftIO $ do
                 stmt <- prepStmt c q
                 bindParams stmt as
                 rows <- stepStmt stmt rts
                 void $ finalize stmt
                 return (reverse rows)
{-# INLINE qry #-}

qrys :: Utf8 -> (TableStmts -> Statement) -> [SType] -> [RType] -> PactSqlLite [[SType]]
qrys tn stmtf as rts = do
  stmt <- stmtf <$> getTableStmts tn
  liftIO $ do
    clearBindings stmt
    bindParams stmt as
    rows <- stepStmt stmt rts
    void $ reset stmt
    return (reverse rows)
{-# INLINE qrys #-}

qry_ :: Utf8 -> [RType] -> PactSqlLite [[SType]]
qry_ q rts = withConn $ \c -> liftIO $ do
            stmt <- prepStmt c q
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
initState c = PSLState M.empty M.empty <$>
            (TxStmts <$> prepStmt c "BEGIN TRANSACTION"
                     <*> prepStmt c "COMMIT TRANSACTION"
                     <*> prepStmt c "ROLLBACK TRANSACTION")

qry1 :: Utf8 -> [SType] -> [RType] -> PactSqlLite [SType]
qry1 q as rts = do
  r <- qry q as rts
  case r of
    [r'] -> return r'
    [] -> throwM $ userError "qry1: no results!"
    rs -> throwM $ userError $ "qry1: multiple results! (" ++ show (length rs) ++ ")"

runPragmas = do
  exec_ "PRAGMA synchronous = OFF"
  exec_ "PRAGMA journal_mode = MEMORY"
  exec_ "PRAGMA locking_mode = EXCLUSIVE"
  exec_ "PRAGMA temp_store = MEMORY"


_run' :: PactSqlLite a -> IO (PSLEnv,(a,PSLState))
_run' a = do
  let f = "foo.sqllite"
  doesFileExist f >>= \b -> when b (removeFile f)
  c <- liftEither $ open (fromString f)
  let env = PSLEnv c
  s <- initState c
  r <- runReaderT (runStateT (runPSL a) s) env
  return (env,r)

_run :: PactSqlLite a -> IO a
_run a = _run' a >>= \(PSLEnv e,(r,_)) -> close e >> return r



_test1 :: IO ()
_test1 =
    _run $ do
      t <- liftIO getCPUTime
      beginTx
      createSchema
      createUserTable' "stuff" "module" "keyset"
      liftIO . print =<< qry_ "select * from usertables" [RText,RText,RText]
      commit'
      beginTx
      liftIO . print =<< getUserTableInfo "stuff"
      writeRow Insert (UserTables "stuff") "key1" (Columns (M.fromList [("gah",PLiteral (LDecimal 123.454345))]))
      liftIO . print =<< readRow (UserTables "stuff") "key1"
      writeRow Update (UserTables "stuff") "key1" (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)]))
      liftIO . print =<< readRow (UserTables "stuff") "key1"
      writeRow Write KeySets "ks1" (PactKeySet [PublicKey "frah"] "stuff")
      liftIO . print =<< readRow KeySets "ks1"
      writeRow Write Modules "mod1" (Module "mod1" "mod-admin-keyset" "code")
      liftIO . print =<< readRow Modules "mod1"
      commit'
      tids <- txids "stuff" (fromIntegral t)
      liftIO $ print tids
      liftIO . print =<< getTxLog (UserTables "stuff") (head tids)

commit' :: PactSqlLite ()
commit' = liftIO getCPUTime >>= \t -> commitTx (fromIntegral t)

runRS e s a = runReaderT (evalStateT (runPSL a) s) e

_bench :: IO ()
_bench = do
  (ie,(_,is)) <- _run' $ do
      beginTx
      createSchema
      createUserTable "stuff" "module" "keyset"
      commitTx 123
      runPragmas
  benchmark $ whnfIO $ runRS ie is $ do
       beginTx
       writeRow Write (UserTables "stuff") "key1" (Columns (M.fromList [("gah",PLiteral (LDecimal 123.454345))]))
       _ <- readRow (UserTables "stuff") "key1"
       writeRow Update (UserTables "stuff") "key1" (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)]))
       r <- readRow (UserTables "stuff") "key1"
       commit'
       return r
  benchmark $ whnfIO $ runRS ie is $ do
       beginTx
       writeRow Update (UserTables "stuff") "key1" (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)]))
       commit'
  benchmark $ whnfIO $ runRS ie is $ do
       beginTx
       writeSys Write "UTBL_stuff" (RowKey "key1") (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)]))
       commit'

parseCompile :: T.Text -> [Term Name]
parseCompile code = compiled where
    (Right es) = AP.parseOnly exprs code
    (Right compiled) = mapM compile es


_pact :: IO ()
_pact = do
  void $ _run' $ do
      cf <- liftIO $ BS.readFile "demo/demo.pact"
      runPragmas
      beginTx
      createSchema
      commit'
      nds <- nativeDefs
      let evalEnv = EvalEnv {
                  _eeRefStore = RefStore nds mempty
                , _eeMsgSigs = mempty
                , _eeMsgBody = object ["keyset" A..= object ["keys" A..= ["demoadmin" :: T.Text], "pred" A..= (">" :: T.Text)]]
                , _eeTxId = 123
                , _eeEntity = "hello"
                , _eePactStep = Nothing
                }
      (r,es) <- runEval def evalEnv $ do
          evalBeginTx
          rs <- mapM eval (parseCompile $ decodeUtf8 cf)
          evalCommitTx
          return rs
      liftIO $ print r
      ie <- ask
      is <- get
      let evalEnv' = over (eeRefStore.rsModules) (HM.union (HM.fromList (_rsNew (_evalRefs es)))) evalEnv
          pactBench benchterm = do
                                tid <- fromIntegral <$> getCPUTime
                                runRS ie is $ runEval def (set eeTxId tid evalEnv') $ do
                                      evalBeginTx
                                      r' <- eval (head benchterm)
                                      evalCommitTx
                                      return r'
      liftIO $ benchmark $ whnfIO $ pactBench $ parseCompile "(demo.transfer \"Acct1\" \"Acct2\" 1.0)"
      liftIO . print =<< readRow (UserTables "demo-accounts") "Acct1"
      liftIO $ benchmark $ whnfIO $ runRS ie is $ readRow (UserTables "demo-accounts") "Acct1"
      liftIO $ benchmark $ whnfIO $ pactBench $ parseCompile "(demo.read-account \"Acct1\")"
      liftIO $ benchmark $ whnfIO $ pactBench $ parseCompile "(demo.fund-account \"Acct1\" 1000.0)"
