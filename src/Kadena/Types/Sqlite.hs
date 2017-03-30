module Kadena.Types.Sqlite where


import Database.SQLite3.Direct as SQ3
import Data.String
import qualified Data.ByteString as BS
import Data.Int
import Prelude hiding (log)
import Control.Monad
import Control.Monad.Catch

-- | Statement input types
data SType = SInt Int64 | SDouble Double | SText Utf8 | SBlob BS.ByteString deriving (Eq,Show)
-- | Result types
data RType = RInt | RDouble | RText | RBlob deriving (Eq,Show)

dbError :: String -> String -> IO a
dbError thrownFrom errMsg = throwM $ userError $ "[" ++ thrownFrom ++ "] DB Error: " ++ errMsg

bindParams :: String -> Statement -> [SType] -> IO ()
bindParams thrownFrom stmt as =
    void $ liftEither thrownFrom
    (sequence <$> forM (zip as [1..]) ( \(a,i) -> do
      case a of
        SInt n -> bindInt64 stmt i n
        SDouble n -> bindDouble stmt i n
        SText n -> bindText stmt i n
        SBlob n -> bindBlob stmt i n))
{-# INLINE bindParams #-}


liftEither :: Show a => String -> IO (Either a b) -> IO b
liftEither thrownFrom a = do
  er <- a
  case er of
    (Left e) -> dbError thrownFrom (show e)
    (Right r) -> return r
{-# INLINE liftEither #-}


prepStmt :: String -> Database -> Utf8 -> IO Statement
prepStmt thrownFrom c q = do
    r <- prepare c q
    case r of
      Left e -> dbError thrownFrom (show e)
      Right Nothing -> dbError thrownFrom "Statement prep failed"
      Right (Just s) -> return s


-- | Prepare/execute query with params
qry :: String -> Database -> Utf8 -> [SType] -> [RType] -> IO [[SType]]
qry thrownFrom e q as rts = do
  stmt <- prepStmt thrownFrom e q
  bindParams thrownFrom stmt as
  rows <- stepStmt thrownFrom stmt rts
  void $ finalize stmt
  return (reverse rows)
{-# INLINE qry #-}


-- | Prepare/execute query with no params
qry_ :: String -> Database -> Utf8 -> [RType] -> IO [[SType]]
qry_ thrownFrom e q rts = do
            stmt <- prepStmt thrownFrom e q
            rows <- stepStmt thrownFrom stmt rts
            _ <- finalize stmt
            return (reverse rows)
{-# INLINE qry_ #-}

-- | Execute query statement with params
qrys :: String -> Statement -> [SType] -> [RType] -> IO [[SType]]
qrys thrownFrom stmt as rts = do
  clearBindings stmt
  bindParams thrownFrom stmt as
  rows <- stepStmt thrownFrom stmt rts
  void $ reset stmt
  return (reverse rows)
{-# INLINE qrys #-}


stepStmt :: String -> Statement -> [RType] -> IO [[SType]]
stepStmt thrownFrom stmt rts = do
  let acc rs Done = return rs
      acc rs Row = do
        as <- forM (zip rts [0..]) $ \(rt,ci) -> do
                      case rt of
                        RInt -> SInt <$> columnInt64 stmt ci
                        RDouble -> SDouble <$> columnDouble stmt ci
                        RText -> SText <$> columnText stmt ci
                        RBlob -> SBlob <$> columnBlob stmt ci
        sr <- liftEither thrownFrom $ step stmt
        acc (as:rs) sr
  sr <- liftEither thrownFrom $ step stmt
  acc [] sr
{-# INLINE stepStmt #-}

-- | Exec statement with no params
execs_ :: String -> Statement -> IO ()
execs_ thrownFrom s = do
  r <- step s
  void $ reset s
  void $ liftEither thrownFrom (return r)
{-# INLINE execs_ #-}


-- | Exec statement with params
execs :: String -> Statement -> [SType] -> IO ()
execs thrownFrom stmt as = do
    clearBindings stmt
    bindParams thrownFrom stmt as
    r <- step stmt
    void $ reset stmt
    void $ liftEither thrownFrom (return r)
{-# INLINE execs #-}

-- | Prepare/exec statement with no params
exec_ :: String -> Database -> Utf8 -> IO ()
exec_ thrownFrom e q = liftEither thrownFrom $ SQ3.exec e q
{-# INLINE exec_ #-}


-- | Prepare/exec statement with params
exec' :: String -> Database -> Utf8 -> [SType] -> IO ()
exec' thrownFrom e q as = do
             stmt <- prepStmt thrownFrom e q
             bindParams thrownFrom stmt as
             r <- step stmt
             void $ finalize stmt
             void $ liftEither thrownFrom (return r)
{-# INLINE exec' #-}
