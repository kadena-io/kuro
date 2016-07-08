
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
import Data.Maybe (fromJust)

import Database.SQLite.Simple (Connection(..))

import Juno.Types.Comms
import Juno.Persistence.SQLite
import Juno.Types.Service.Log as X
import Juno.Types (startIndex)

runLogService :: LogServiceChannel -> (String -> IO()) -> FilePath -> IO ()
runLogService lsc dbg dbPath = do
  dbConn' <- return Nothing -- if null dbPath then Just <$> createDB dbPath else return Nothing
  env <- return $ LogEnv lsc dbg dbConn'
  initLogState' <- case dbConn' of
    Just conn' -> syncLogsFromDisk conn'
    Nothing -> return $ initLogState
  void $ runRWST handle env initLogState'

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
  toPersist <- getUnpersisted <$> get
  case toPersist of
    Just logs -> do
      dbConn' <- view dbConn
      lsLastPersisted .= (_leLogIndex $ fromJust $ seqTail logs)
      case dbConn' of
        Just conn -> liftIO $ insertSeqLogEntry conn logs
        Nothing ->  return ()
    Nothing -> return ()
runQuery (Tick t) = do
  t' <- liftIO $ pprintTock t "runQuery"
  debug t'

syncLogsFromDisk :: Connection -> IO (LogState LogEntry)
syncLogsFromDisk conn = do
  logs <- selectAllLogEntries conn
  lastLog' <- return $ seqTail logs
  case lastLog' of
    Just log' -> return $ LogState
      { _lsLogEntries = Log logs
      , _lsLastApplied = startIndex
      , _lsLastLogIndex = _leLogIndex log'
      , _lsNextLogIndex = (_leLogIndex log') + 1
      , _lsCommitIndex = _leLogIndex log'
      , _lsLastPersisted = _leLogIndex log'
      , _lsLastLogTerm = _leTerm log'
      }
    Nothing -> return $ initLogState
