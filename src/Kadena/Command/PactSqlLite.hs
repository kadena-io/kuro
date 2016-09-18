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
import Database.SQLite.Simple
import Database.SQLite.Simple.Ok
import Database.SQLite.Simple.ToField
import Database.SQLite.Simple.FromField
import qualified Data.Text as T
import System.IO
import System.Directory
import Control.Monad
import Data.Monoid
import Control.Arrow
import Control.Lens
import Data.String
import Data.Aeson
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import Criterion
import Control.Concurrent

import Pact.Types


instance FromField TableName where fromField f = TableName <$> fromField f
instance FromField RowKey where fromField f = RowKey <$> fromField f

instance ToField RowKey where toField (RowKey k) = toField k
instance ToField KeySetName where toField (KeySetName k) = toField k
instance ToField ModuleName where toField (ModuleName m) = toField m

instance ToField (Columns Persistable) where
    toField = toJSONField
    {-# INLINE toField #-}
instance FromField (Columns Persistable) where
    fromField f = fromJSONField f
    {-# INLINE fromField #-}

instance ToField Module where
    toField = toJSONField
    {-# INLINE toField #-}
instance FromField Module where
    fromField = fromJSONField
    {-# INLINE fromField #-}

instance ToField PactKeySet where
    toField = toJSONField
    {-# INLINE toField #-}
instance FromField PactKeySet where
    fromField = fromJSONField
    {-# INLINE fromField #-}

toJSONField :: ToJSON a => a -> SQLData
toJSONField f = toField (encode f)
{-# INLINE toJSONField #-}

fromJSONField :: FromJSON b => Field -> Ok b
fromJSONField f = do
      v <- eitherDecodeStrict' <$> fromField f
      case v of
        Left err -> fail err
        Right c -> return c
{-# INLINE fromJSONField #-}

data PSLEnv = PSLEnv {
      conn :: Connection
}

newtype PactSqlLite a = PactSqlLite { runPSL :: ReaderT PSLEnv IO a }
    deriving (Functor,Applicative,Monad,MonadReader PSLEnv,MonadCatch,MonadThrow,MonadIO)

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
    keys tn = map fromOnly <$> qry_ ("select key from " <> userTable tn <> " order by key")


    -- txids :: TableName -> TxId -> m [TxId]


    -- createUserTable :: TableName -> ModuleName -> KeySetName -> m ()
    createUserTable tn mn ksn = createTable tn mn ksn


    -- getUserTableInfo :: TableName -> m (ModuleName,KeySetName)
    getUserTableInfo tn = qry1 "select module, keyset from usertables where name=?"
                          (Only (asString tn)) <&> (fromString *** fromString)

    -- beginTx :: m ()
    beginTx = exec_ "BEGIN TRANSACTION"


    -- commitTx :: TxId -> m ()
    commitTx _ = exec_ "COMMIT TRANSACTION"


    -- rollbackTx :: m ()
    rollbackTx = exec_ "ROLLBACK TRANSACTION"

    -- getTxLog :: Domain d k v -> TxId -> m [TxLog]

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

readRow' :: (ToField k,FromField v,Show k) => Domain d k v -> T.Text -> k -> PactSqlLite (Maybe v)
readRow' _ t k = do
  r <- qry ("select value from " <> t <> " where key = ?") (Only k)
  case r of
    [] -> return Nothing
    [Only a] -> return $ Just a
    _ -> throwError $ "read: more than one row found for table " ++ show t ++ ", key " ++ show k
{-# INLINE readRow' #-}

throwError :: MonadThrow m => String -> m a
throwError s = throwM (userError s)

writeSys :: (ToField k,ToField v) =>  WriteType -> T.Text -> k -> v -> PactSqlLite ()
writeSys wt tbl k v =
    let q = case wt of
              Write -> "INSERT OR REPLACE INTO " <> tbl <> " VALUES (?,?)"
              Insert -> "INSERT INTO " <> tbl <> " VALUES (?,?)"
              Update -> "REPLACE INTO " <> tbl <> " VALUES (?,?)"
    in exec q (k,v)
{-# INLINE writeSys #-}

writeUser :: WriteType -> TableName -> RowKey -> Columns Persistable -> PactSqlLite ()
writeUser wt tn rk row = do
  let ut = userTable tn
  olds <- qry ("select value from " <> ut <> " where key = ?") (Only rk)
  let ins = exec ("INSERT INTO " <> ut <> " VALUES (?,?)") (rk,row)
      upd old = exec ("REPLACE INTO " <> ut <> " VALUES (?,?)")
                (rk,Columns (M.union (_columns row) (_columns old)))
  case (olds,wt) of
    ([],Insert) -> ins
    (_,Insert) -> throwError $ "Insert: row found for key " ++ show rk
    ([],Write) -> ins
    ([Only old],Write) -> upd old
    (_,Write) -> throwError $ "Write: more than one row found for key " ++ show rk
    ([Only old],Update) -> upd old
    ([],Update) -> throwError $ "Update: no row found for key " ++ show rk
    (_,Update) -> throwError $ "Update: more than one row found for key " ++ show rk
{-# INLINE writeUser #-}

withConn :: (Connection -> PactSqlLite a) -> PactSqlLite a
withConn f = reader conn >>= \c -> f c

userTable :: TableName -> T.Text
userTable tn = "USER_" <> T.pack (asString tn)
keysetsTable :: T.Text
keysetsTable = "SYS_keysets"
modulesTable :: T.Text
modulesTable = "SYS_modules"

createTable :: TableName -> ModuleName -> KeySetName -> PactSqlLite ()
createTable tn mn ksn = do
    exec_ $ createKV $ userTable tn
    exec "insert into usertables values (?,?,?)"
             (asString tn,asString mn,asString ksn)

createKV :: T.Text -> T.Text
createKV t = "create table " <> t <>
              " (key text primary key not null unique, value SQLBlob not null)"

createUTInfo :: T.Text
createUTInfo =
    "CREATE TABLE IF NOT EXISTS usertables (\
    \ name TEXT PRIMARY KEY NOT NULL UNIQUE \
    \,module text NOT NULL \
    \,keyset text NOT NULL) \
    \"


createSchema :: PactSqlLite ()
createSchema = do
  exec_ createUTInfo
  exec_ $ createKV keysetsTable
  exec_ $ createKV modulesTable

exec_ :: T.Text -> PactSqlLite ()
exec_ q = withConn $ \c -> liftIO $ execute_ c (Query q)

exec :: ToRow a => T.Text -> a -> PactSqlLite ()
exec q a = withConn $ \c -> liftIO $ execute c (Query q) a

qry :: (ToRow q, FromRow r) => T.Text -> q -> PactSqlLite [r]
qry q v = withConn $ \c -> liftIO $ query c (Query q) v

qry_ :: (FromRow r) => T.Text -> PactSqlLite [r]
qry_ q  = withConn $ \c -> liftIO $ query_ c (Query q)


qry1 :: (ToRow q, FromRow r) => T.Text -> q -> PactSqlLite r
qry1 q v = do
  r <- qry q v
  case r of
    [r'] -> return r'
    [] -> throwM $ userError "qry1: no results!"
    rs -> throwM $ userError $ "qry1: multiple results! (" ++ show (length rs) ++ ")"


_run' :: PactSqlLite a -> IO (PSLEnv,a)
_run' a = do
  let f = "foo.sqllite"
  doesFileExist f >>= \b -> when b (removeFile f)
  c <- open f
  r <- runReaderT (runPSL a) (PSLEnv c)
  return (PSLEnv c,r)

_run :: PactSqlLite a -> IO a
_run a = _run' a >>= \(PSLEnv e,r) -> close e >> return r



_test1 =
    _run $ do
      beginTx
      createSchema
      createTable "stuff" "module" "keyset"
      commitTx 123
      liftIO . print =<< getUserTableInfo "stuff"
      writeRow Insert (UserTables "stuff") "key1" (Columns (M.fromList [("gah",PLiteral (LDecimal 123.454345))]))
      liftIO . print =<< readRow (UserTables "stuff") "key1"
      writeRow Update (UserTables "stuff") "key1" (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)]))
      liftIO . print =<< readRow (UserTables "stuff") "key1"
      writeRow Write KeySets "ks1" (PactKeySet [PublicKey "frah"] "stuff")
      liftIO . print =<< readRow KeySets "ks1"
      writeRow Write Modules "mod1" (Module "mod1" "mod-admin-keyset" "code")
      liftIO . print =<< readRow Modules "mod1"


_bench :: IO ()
_bench = do
  (e,_) <- _run' $ do
      beginTx
      createSchema
      createTable "stuff" "module" "keyset"
      commitTx 123
      exec_ "PRAGMA synchronous = OFF"
      exec_ "PRAGMA journal_mode = MEMORY"
  benchmark $ whnfIO $ ((`runReaderT` e) . runPSL) $ do
       beginTx
       writeRow Write (UserTables "stuff") "key1" (Columns (M.fromList [("gah",PLiteral (LDecimal 123.454345))]))
       _ <- readRow (UserTables "stuff") "key1"
       writeRow Update (UserTables "stuff") "key1" (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)]))
       r <- readRow (UserTables "stuff") "key1"
       commitTx 234
       return r
  benchmark $ whnfIO $ ((`runReaderT` e) . runPSL) $ do
       beginTx
       writeRow Update (UserTables "stuff") "key1" (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)]))
       commitTx 234
  benchmark $ whnfIO $ ((`runReaderT` e) . runPSL) $ do
       beginTx
       writeSys Write "USER_stuff" (RowKey "key1") (Columns (M.fromList [("gah",PLiteral (LBool False)),("fh",PValue Null)]))
       commitTx 234
