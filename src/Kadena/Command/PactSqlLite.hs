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
import Database.SQLite3.Direct as SQ3
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
import Data.Text.Encoding
import Data.Int

import Pact.Types

{-

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

-}

data PSLEnv = PSLEnv {
      conn :: Database
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
    keys tn = undefined -- map fromOnly <$> qry_ ("select key from " <> userTable tn <> " order by key")


    -- txids :: TableName -> TxId -> m [TxId]


    -- createUserTable :: TableName -> ModuleName -> KeySetName -> m ()
    createUserTable tn mn ksn = createTable tn mn ksn


    -- getUserTableInfo :: TableName -> m (ModuleName,KeySetName)
    getUserTableInfo tn = do
      [m,k] <- qry1 "select module, keyset from usertables where name=?" [stext tn] [RText,RText]
      (,) <$> decodeText m <*> decodeText k

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

readRow' :: (AsString k,FromJSON v,Show k) => Domain d k v -> Utf8 -> k -> PactSqlLite (Maybe v)
readRow' _ t k = do
  r <- qry ("select value from " <> t <> " where key = ?") [stext k] [RBlob]
  case r of
    [] -> return Nothing
    [a] -> Just <$> decodeBlob a
    _ -> throwError $ "read: more than one row found for table " ++ show t ++ ", key " ++ show k
{-# INLINE readRow' #-}

throwError :: MonadThrow m => String -> m a
throwError s = throwM (userError s)

writeSys :: (AsString k,ToJSON v) => WriteType -> Utf8 -> k -> v -> PactSqlLite ()
writeSys wt tbl k v =
    let q = case wt of
              Write -> "INSERT OR REPLACE INTO " <> tbl <> " VALUES (?,?)"
              Insert -> "INSERT INTO " <> tbl <> " VALUES (?,?)"
              Update -> "REPLACE INTO " <> tbl <> " VALUES (?,?)"
    in exec' q [stext k,sencode v]
{-# INLINE writeSys #-}

writeUser :: WriteType -> TableName -> RowKey -> Columns Persistable -> PactSqlLite ()
writeUser wt tn rk row = do
  let ut = userTable tn
  olds <- qry ("select value from " <> ut <> " where key = ?") [stext rk] [RBlob]
  let ins = exec' ("INSERT INTO " <> ut <> " VALUES (?,?)") [stext rk,sencode row]
      upd old = do
        oldrow <- decodeBlob old
        exec' ("REPLACE INTO " <> ut <> " VALUES (?,?)")
                [stext rk,
                 sencode (Columns (M.union (_columns row) (_columns oldrow)))]
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

decodeBlob :: (FromJSON v) => [SType] -> PactSqlLite v
decodeBlob [SBlob old] = liftEither (return $ eitherDecodeStrict' old)
decodeBlob v = throwError $ "Expected single-column blob, got: " ++ show v

decodeText :: (IsString v) => SType -> PactSqlLite v
decodeText (SText (Utf8 t)) = return $ fromString $ T.unpack $ decodeUtf8 t
decodeText v = throwError $ "Expected text, got: " ++ show v

withConn :: (Database -> PactSqlLite a) -> PactSqlLite a
withConn f = reader conn >>= \c -> f c

userTable :: TableName -> Utf8
userTable tn = "USER_" <> fromString (asString tn)
keysetsTable :: Utf8
keysetsTable = "SYS_keysets"
modulesTable :: Utf8
modulesTable = "SYS_modules"

sencode :: ToJSON a => a -> SType
sencode a = SBlob $ BSL.toStrict $ encode a

stext :: AsString a => a -> SType
stext a = SText $ fromString $ asString a

data SType = SInt Int64 | SDouble Double | SText Utf8 | SBlob BS.ByteString deriving (Eq,Show)
data RType = RInt | RDouble | RText | RBlob deriving (Eq,Show)



createTable :: TableName -> ModuleName -> KeySetName -> PactSqlLite ()
createTable tn mn ksn = do
    exec_ $ createKV $ userTable tn
    exec' "insert into usertables values (?,?,?)"
             [stext tn,stext mn,stext ksn]

createKV :: Utf8 -> Utf8
createKV t = "create table " <> t <>
              " (key text primary key not null unique, value SQLBlob not null);"

createUTInfo :: Utf8
createUTInfo =
    "CREATE TABLE IF NOT EXISTS usertables (\
    \ name TEXT PRIMARY KEY NOT NULL UNIQUE \
    \,module text NOT NULL \
    \,keyset text NOT NULL);"


createSchema :: PactSqlLite ()
createSchema = do
  exec_ createUTInfo
  exec_ $ createKV keysetsTable
  exec_ $ createKV modulesTable

exec_ :: Utf8 -> PactSqlLite ()
exec_ q = withConn $ \c -> liftIO $ liftEither $ SQ3.exec c q

liftEither a = do
  r <- a
  case r of
    (Left e) -> throwError (show e)
    (Right r) -> return r

exec' :: Utf8 -> [SType] -> PactSqlLite ()
exec' q as = withConn $ \c -> liftIO $ do
             stmt <- prepStmt c q
             bindParams stmt as
             r <- step stmt
             finalize stmt
             const () <$> liftEither (return r)

bindParams :: Statement -> [SType] -> IO ()
bindParams stmt as =
    const () <$> liftEither
    (sequence <$> forM (zip as [1..]) ( \(a,pi) -> do
      case a of
        SInt n -> bindInt64 stmt pi n
        SDouble n -> bindDouble stmt pi n
        SText n -> bindText stmt pi n
        SBlob n -> bindBlob stmt pi n))

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
                 finalize stmt
                 return (reverse rows)

qry_ :: Utf8 -> [RType] -> PactSqlLite [[SType]]
qry_ q rts = withConn $ \c -> liftIO $ do
            stmt <- prepStmt c q
            rows <- stepStmt stmt rts
            finalize stmt
            return (reverse rows)

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



qry1 :: Utf8 -> [SType] -> [RType] -> PactSqlLite [SType]
qry1 q as rts = do
  r <- qry q as rts
  case r of
    [r'] -> return r'
    [] -> throwM $ userError "qry1: no results!"
    rs -> throwM $ userError $ "qry1: multiple results! (" ++ show (length rs) ++ ")"


_run' :: PactSqlLite a -> IO (PSLEnv,a)
_run' a = do
  let f = "foo.sqllite"
  doesFileExist f >>= \b -> when b (removeFile f)
  c <- liftEither $ open (fromString f)
  r <- runReaderT (runPSL a) (PSLEnv c)
  return (PSLEnv c,r)

_run :: PactSqlLite a -> IO a
_run a = _run' a >>= \(PSLEnv e,r) -> close e >> return r



_test1 =
    _run $ do
      beginTx
      createSchema
      createTable "stuff" "module" "keyset"
      liftIO . print =<< qry_ "select * from usertables" [RText,RText,RText]
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
