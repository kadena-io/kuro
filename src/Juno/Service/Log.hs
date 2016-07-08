
module Juno.Service.Log
  ( runLogService
  , module X)
  where

import Control.Lens hiding (Index, (|>))
import Control.Concurrent (putMVar)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict

import qualified Data.Map.Strict as Map

import Juno.Types.Comms
import Juno.Persistence.SQLite
import Juno.Types.Service.Log as X

runLogService :: LogServiceChannel -> (String -> IO()) -> FilePath -> IO ()
runLogService lsc dbg dbPath = do
  dbConn' <- createDB dbPath
  env <- return $ LogEnv lsc dbg dbConn'
  void $ runRWST handle env initLogState

debug :: String -> LogThread ()
debug s = do
  dbg <- view debugPrint
  liftIO $ dbg $ "[LogThread] " ++ s

handle :: LogThread ()
handle = do
  oChan <- view logQueryChannel
  debug "Begin"
  forever $ do
    q <- liftIO $ readComm oChan
    runQuery q

runQuery :: QueryApi -> LogThread ()
runQuery (Query aq mv) = do
  a' <- get
  qr <- return $ Map.fromSet (`evalQuery` a') aq
  liftIO $ putMVar mv qr
runQuery (Update ul) = do
  modify (\a' -> updateLogs ul a')
  toPersist <- getUnappliedEntries <$> get
  case toPersist of
    Just logs -> do
      dbConn' <- view dbConn
      liftIO $ insertSeqLogEntry dbConn' logs
    Nothing -> return ()
runQuery (Tick t) = do
  t' <- liftIO $ pprintTock t "runQuery"
  debug t'
