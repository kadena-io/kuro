
module Juno.Service.Log
  ( runLogService
  , module X)
  where

import Control.Lens hiding (Index, (|>))
import Control.Concurrent (MVar, putMVar, swapMVar)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict

import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust)

import Database.SQLite.Simple (Connection(..))

import Juno.Types.Comms
import Juno.Persistence.SQLite
import Juno.Types.Service.Log as X
import qualified Juno.Types.Service.Evidence as Ev
import qualified Juno.Types.Dispatch as Dispatch
import Juno.Types (startIndex, Event(ApplyLogEntries), Dispatch)


runLogService :: Dispatch -> (String -> IO()) -> FilePath -> MVar Ev.EvidenceCache -> IO ()
runLogService dispatch dbg dbPath mEvCache = do
  dbConn' <- if not (null dbPath)
    then do
      dbg $ "[LogThread] Database Connection Opened: " ++ dbPath
      Just <$> createDB dbPath
    else do
      dbg "[LogThread] Persistence Disabled"
      return Nothing
  env <- return $ LogEnv (dispatch ^. Dispatch.logService) (dispatch ^. Dispatch.internalEvent) dbg dbConn' mEvCache
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
  updateEvidenceCache ul
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

updateEvidenceCache :: UpdateLogs -> LogThread ()
updateEvidenceCache (UpdateLastApplied _) = return ()
-- In these cases, we need to update the cache because we have something new
updateEvidenceCache (ULNew _) = updateEvidenceCache'
updateEvidenceCache (ULReplicate _) = updateEvidenceCache'
updateEvidenceCache (ULCommitIdx _) = tellJunoToApplyLogEntries >> updateEvidenceCache'

-- For pattern matching totality checking goodness
updateEvidenceCache' :: LogThread ()
updateEvidenceCache' = do
  ci <- use lsCommitIndex
  lli <- use lsLastLogIndex
  llt <- use lsLastLogTerm
  ciHash <- (lookupEntry ci <$> get) >>= return . maybe mempty _leHash
  mEvCache <- view evidenceCache
  if ci == lli
  then do
    -- In this case, there's no new hashes to compare evidence against. Basically a steady state
    void $ liftIO $ swapMVar mEvCache $ Ev.EvidenceCache
        { Ev.minLogIdx = ci + 1
        , Ev.maxLogIdx = ci + 1
        , Ev.lastLogTerm = llt
        , Ev.hashes = mempty
        , Ev.hashAtCommitIndex = ciHash
        }
  else do
    -- We have uncommited entries
    hashes <- getUncommitedHashes <$> get
    void $ liftIO $ swapMVar mEvCache $ Ev.EvidenceCache
        { Ev.minLogIdx = ci + 1
        , Ev.maxLogIdx = lli
        , Ev.lastLogTerm = llt
        , Ev.hashes = hashes
        , Ev.hashAtCommitIndex = ciHash
        }

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

tellJunoToApplyLogEntries :: LogThread ()
tellJunoToApplyLogEntries = do
  view internalEvent >>= liftIO . (`writeComm` (InternalEvent ApplyLogEntries))
