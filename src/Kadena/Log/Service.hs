{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}

module Kadena.Log.Service
  ( runLogService
  , module X)
  where

import Control.Lens hiding (Index, (|>))
import Control.Concurrent (putMVar)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict

import Data.Maybe (catMaybes, isNothing)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import System.FilePath

import Data.Thyme.Clock
import Database.SQLite.Simple (Connection(..))

import Kadena.Types.Base
import Kadena.Types.Comms
import Kadena.Types.Config
import Kadena.Types.Command (CmdLatencyMetrics(..))
import Kadena.Types.Metric
import Kadena.Log.Persistence
import Kadena.Log.Types as X
import Kadena.Log.LogApi as X
import qualified Kadena.Evidence.Spec as Ev
import qualified Kadena.Types.Dispatch as Dispatch
import qualified Kadena.Commit.Types as Commit
import Kadena.Types (Dispatch)

runLogService :: Dispatch
              -> (String -> IO())
              -> (Metric -> IO())
              -> KeySet
              -> Config
              -> IO ()
runLogService dispatch dbg publishMetric' keySet' rconf = do
  dbConn' <- if rconf ^. enablePersistence
    then do
      let dbDir' = (rconf ^. logDir) </> (show $ _alias $ rconf ^. (nodeId)) ++ "-log.sqlite"
      dbg $ "[Service|Log] Database Connection Opened: " ++ dbDir'
      Just <$> createDB dbDir'
    else do
      dbg "[Service|Log] Persistence Disabled"
      return Nothing
  env <- return LogEnv
    { _logQueryChannel = dispatch ^. Dispatch.logService
    , _internalEvent = dispatch ^. Dispatch.internalEvent
    , _commitChannel = dispatch ^. Dispatch.commitService
    , _evidence = dispatch ^. Dispatch.evidence
    , _senderChannel = dispatch ^. Dispatch.senderService
    , _debugPrint = dbg
    , _keySet = keySet'
    , _persistedLogEntriesToKeepInMemory = (rconf ^. inMemTxCache)
    , _dbConn = dbConn'
    , _publishMetric = publishMetric'
    }
  initLogState' <- case dbConn' of
    Just conn' -> syncLogsFromDisk (env ^. persistedLogEntriesToKeepInMemory) (dispatch ^. Dispatch.commitService) conn'
    Nothing -> return initLogState
  void $ runRWST handle env initLogState'

debug :: String -> LogThread ()
debug s = do
  dbg <- view debugPrint
  liftIO $ dbg $ "[Service|Log]: " ++ s

handle :: LogThread ()
handle = do
  clearPersistedEntriesFromMemory
  oChan <- view logQueryChannel
  debug "launch!"
  forever $ do
    q <- liftIO $ readComm oChan
    runQuery q

runQuery :: QueryApi -> LogThread ()
runQuery (Query aq mv) = do
  start <- liftIO $ getCurrentTime
  qr <- Map.fromList <$> mapM (\aq' -> evalQuery aq' >>= \res -> return $ (aq', res)) (Set.toList aq)
  liftIO $ putMVar mv $! qr
  end <- liftIO $ getCurrentTime
  debug $ "Query executed (" ++ show (interval start end) ++ "mics)"
runQuery (Update ul) = do
  updateLogs ul
  updateEvidenceCache ul
  dbConn' <- view dbConn
  case dbConn' of
    Just conn -> do
      toPersist <- getUnpersisted
      case toPersist of
        Just logs -> do
          start <- liftIO $ getCurrentTime
          lsLastPersisted' <- return (_leLogIndex $ snd $ Map.findMax (logs ^. logEntries))
          lsLastPersisted .= lsLastPersisted'
          lsPersistedLogEntries %= plesAddNew logs
          lsVolatileLogEntries %= lesGetSection (Just $ lsLastPersisted' + 1) Nothing
          liftIO $ insertSeqLogEntry conn logs
          end <- liftIO $ getCurrentTime
          debug $ "Persisted " ++ show (lesCnt logs) ++ " to disk (" ++ show (interval start end) ++ "mics)"
          clearPersistedEntriesFromMemory
        Nothing -> return ()
    Nothing ->  return ()
runQuery (NeedCacheEvidence lis mv) = do
  qr <- buildNeedCacheEvidence lis
  liftIO $ putMVar mv $! qr
  debug $ "servicing cache miss pertaining to: " ++ show lis
runQuery (Heart t) = do
  t' <- liftIO $ pprintBeat t
  debug t'
  volLEs <- use lsVolatileLogEntries
  perLes@(PersistedLogEntries _perLes') <- use lsPersistedLogEntries
  debug $ "Memory "
        ++ "{ V: " ++ show (lesCnt volLEs)
        ++ ", P: " ++ show (plesCnt perLes) ++ " }"

buildNeedCacheEvidence :: Set LogIndex -> LogThread (Map LogIndex Hash)
buildNeedCacheEvidence lis = do
  let go li = maybe Nothing (\le -> Just $ (li,_leHash le)) <$> lookupEntry li
  Map.fromAscList . catMaybes <$> mapM go (Set.toAscList lis)
{-# INLINE buildNeedCacheEvidence #-}

updateEvidenceCache :: UpdateLogs -> LogThread ()
updateEvidenceCache (UpdateLastApplied _) = return ()
-- In these cases, we need to update the cache because we have something new
updateEvidenceCache (ULNew _) = updateEvidenceCache'
updateEvidenceCache (ULReplicate _) = updateEvidenceCache'
updateEvidenceCache (ULCommitIdx (UpdateCommitIndex _ ts)) = do
  tellKadenaToApplyLogEntries ts
#if WITH_KILL_SWITCH
  when (_ci >= 200000) $
    error "Thank you for using Kadena, this demo is limited to 200k log entries."
#endif

-- For pattern matching totality checking goodness
updateEvidenceCache' :: LogThread ()
updateEvidenceCache' = do
  lli <- use lsLastLogIndex
  llh <- use lsLastLogHash
  evChan <- view evidence
  liftIO $ writeComm evChan $ Ev.CacheNewHash lli llh
  debug $ "Sent new evidence to cache for: " ++ show lli

-- TODO: currently, when syncing from disk, we read everything into memory. This is bad
syncLogsFromDisk :: Int -> Commit.CommitChannel -> Connection -> IO LogState
syncLogsFromDisk keepInMem commitChannel' conn = do
  logs@(LogEntries logs') <- selectAllLogEntries conn
  lastLog' <- return $! lesMaxEntry logs
  case lastLog' of
    Just log' -> do
      liftIO $ writeComm commitChannel' $ Commit.ReloadFromDisk logs
      (Just maxIdx) <- return $ lesMaxIndex logs
      pLogs <- return $! (`plesAddNew` plesEmpty) $! LogEntries $! Map.filterWithKey (\k _ -> k > (maxIdx - fromIntegral keepInMem)) logs'
      return LogState
        { _lsVolatileLogEntries = LogEntries Map.empty
        , _lsPersistedLogEntries = pLogs
        , _lsLastApplied = startIndex
        , _lsLastLogIndex = _leLogIndex log'
        , _lsLastLogHash = _leHash log'
        , _lsNextLogIndex = _leLogIndex log' + 1
        , _lsCommitIndex = _leLogIndex log'
        , _lsLastPersisted = _leLogIndex log'
        , _lsLastInMemory = plesMinIndex pLogs
        , _lsLastLogTerm = _leTerm log'
        }
    Nothing -> return initLogState

populateConsensusLatency :: UTCTime -> UTCTime -> LogEntries -> LogEntries
populateConsensusLatency aerTime logTime LogEntries{..} =
  let
    popLats l = l { _lmLogConsensus = Just logTime
                  , _lmAerConsensus = Just aerTime}
    les' = over leCmdLatMetrics (fmap popLats) <$> _logEntries
  in LogEntries $! les'
{-# INLINE populateConsensusLatency #-}

tellKadenaToApplyLogEntries :: UTCTime -> LogThread ()
tellKadenaToApplyLogEntries aerTime = do
  mUnappliedEntries' <- getUnappliedEntries
  case mUnappliedEntries' of
    Just unappliedEntries' -> do
      (Just appliedIndex') <- return $ lesMaxIndex unappliedEntries'
      lsLastApplied .= appliedIndex'
      logTime <- liftIO getCurrentTime
      ues' <- return $ populateConsensusLatency aerTime logTime unappliedEntries'
      view commitChannel >>= liftIO . (`writeComm` Commit.CommitNewEntries ues')
      debug $ "informing Kadena to apply up to: " ++ show appliedIndex'
      publishMetric' <- view publishMetric
      liftIO $ publishMetric' $ MetricCommitIndex appliedIndex'
    Nothing -> return ()

clearPersistedEntriesFromMemory :: LogThread ()
clearPersistedEntriesFromMemory = do
  conn' <- view dbConn
  unless (isNothing conn') $ do
    cnt <- view persistedLogEntriesToKeepInMemory
    commitIndex' <- commitIndex
    oldPles@(PersistedLogEntries _oldPles') <- use lsPersistedLogEntries
    previousLastInMemory <- use lsLastInMemory
    (_mKey, newPles@(PersistedLogEntries _newPles')) <- return $! plesTakeTopEntries cnt oldPles
    case plesMinIndex newPles of
      Nothing | newPles /= oldPles -> error $ "Invariant Failure in clearPersistedEntriesFromMemory: attempted to get the minIdx, got nothing, but persisted entries was changed!"
                                         ++ "\ncommitIndex: " ++ show commitIndex'
                                         ++ "\nprevLastInMemory: " ++ show previousLastInMemory
                                         ++ "\nples: " ++ show (Map.keysSet $ _pLogEntries oldPles)
                                         ++ "\nnewPles: " ++ show (Map.keysSet $ _pLogEntries newPles)
              | otherwise -> return ()
      Just newMin -> do
        lsLastInMemory .= Just newMin
        debug $ "Memory Cleared from " ++ maybe "Nothing" show previousLastInMemory ++ " up to " ++ show newMin
    lsPersistedLogEntries .= newPles
-- Keep this around incase there's another issue with the clearer
--    volLEs <- use lsVolatileLogEntries
--    oldPMap <- return $! (\(k,v) -> (k, (maybe "Nothing" show $ lesMinIndex v, lesCnt v))) <$> Map.toDescList oldPles'
--    newPMap <- return $! (\(k,v) -> (k, (maybe "Nothing" show $ lesMinIndex v, lesCnt v))) <$> Map.toDescList newPles'
--    debug $ "## Log Entries In Memory ##"
--          ++ "\n  Volatile: " ++ show (lesCnt volLEs)
--          ++ "\n Persisted: " ++ show (plesCnt newPles)
--          ++ "\n Split Key: " ++ show mKey
--          ++ "\n OldPerMap: " ++ show oldPMap
--          ++ "\n NewPerMap: " ++ show newPMap
