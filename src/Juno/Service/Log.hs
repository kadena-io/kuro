
module Juno.Service.Log
  ( runLogService
  , module X)
  where

import Control.Lens hiding (Index, (|>))
import Control.Concurrent (MVar, putMVar, swapMVar)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Maybe (fromJust)

import Database.SQLite.Simple (Connection(..))

import Juno.Types.Comms
import Juno.Persistence.SQLite
import Juno.Types.Service.Log as X
import qualified Juno.Types.Service.Evidence as Ev
import qualified Juno.Types.Dispatch as Dispatch
import Juno.Types (startIndex, Event(ApplyLogEntries), Dispatch)

runLogService :: Dispatch -> (String -> IO()) -> FilePath -> IO ()
runLogService dispatch dbg dbPath = do
  dbConn' <- if not (null dbPath)
    then do
      dbg $ "[LogThread] Database Connection Opened: " ++ dbPath
      Just <$> createDB dbPath
    else do
      dbg "[LogThread] Persistence Disabled"
      return Nothing
  env <- return $ LogEnv
    { _logQueryChannel = (dispatch ^. Dispatch.logService)
    , _internalEvent = (dispatch ^. Dispatch.internalEvent)
    , _evidence = (dispatch ^. Dispatch.evidence)
    , _debugPrint = dbg
    , _dbConn = dbConn'
    }
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
  dbConn' <- view dbConn
  case dbConn' of
    Just conn -> do
      toPersist <- getUnpersisted <$> get
      case toPersist of
        Just logs -> do
          lsLastPersisted .= (_leLogIndex $ fromJust $ seqTail logs)
          liftIO $ insertSeqLogEntry conn logs
        Nothing -> return ()
    Nothing ->  return ()
runQuery (NeedCacheEvidence lis mv) = do
  qr <- buildNeedCacheEvidence lis <$> get
  liftIO $ putMVar mv qr
  debug $ "Servicing cache miss pertaining to: " ++ show lis
runQuery (Tick t) = do
  t' <- liftIO $ pprintTock t "runQuery"
  debug t'

buildNeedCacheEvidence :: Set LogIndex -> LogState LogEntry -> Map LogIndex ByteString
buildNeedCacheEvidence lis ls = res `seq` res
  where
    res = Map.fromAscList $ go $ Set.toAscList lis
    go [] = []
    go (li:rest) = case lookupEntry li ls of
      Nothing -> go rest
      Just le -> (li,_leHash le) : go rest
{-# INLINE buildNeedCacheEvidence #-}

updateEvidenceCache :: UpdateLogs -> LogThread ()
updateEvidenceCache (UpdateLastApplied _) = return ()
-- In these cases, we need to update the cache because we have something new
updateEvidenceCache (ULNew _) = updateEvidenceCache'
updateEvidenceCache (ULReplicate _) = updateEvidenceCache'
updateEvidenceCache (ULCommitIdx _) = tellJunoToApplyLogEntries

-- For pattern matching totality checking goodness
updateEvidenceCache' :: LogThread ()
updateEvidenceCache' = do
  lli <- use lsLastLogIndex
  llh <- use lsLastLogHash
  evChan <- view evidence
  liftIO $ writeComm evChan $ Ev.CacheNewHash lli llh
  debug $ "Sent new evidence to cache for: " ++ show lli

syncLogsFromDisk :: Connection -> IO (LogState LogEntry)
syncLogsFromDisk conn = do
  logs <- selectAllLogEntries conn
  lastLog' <- return $ seqTail logs
  case lastLog' of
    Just log' -> return $ LogState
      { _lsLogEntries = Log logs
      , _lsLastApplied = startIndex
      , _lsLastLogIndex = _leLogIndex log'
      , _lsLastLogHash = _leHash log'
      , _lsNextLogIndex = (_leLogIndex log') + 1
      , _lsCommitIndex = _leLogIndex log'
      , _lsLastPersisted = _leLogIndex log'
      , _lsLastLogTerm = _leTerm log'
      }
    Nothing -> return $ initLogState

tellJunoToApplyLogEntries :: LogThread ()
tellJunoToApplyLogEntries = do
  es <- get
  unappliedEntries' <- return $ getUnappliedEntries es
  commitIndex' <- return $ es ^. lsCommitIndex
  view internalEvent >>= liftIO . (`writeComm` (InternalEvent $ ApplyLogEntries unappliedEntries' commitIndex'))
  debug $ "informing Juno of a CommitIndex update: " ++ show commitIndex'
