{-# LANGUAGE BangPatterns #-}

module Kadena.Log.Service
  ( runLogService
  , module X)
  where

import Control.Lens hiding (Index, (|>))
import Control.Concurrent (putMVar)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict

import Data.Maybe (catMaybes, isNothing)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set

import Data.Thyme.Clock
import Database.SQLite.Simple (Connection(..))

import Kadena.Types.Comms
import Kadena.Types.Metric
import Kadena.Log.Persistence
import Kadena.Types.Service.Log as X
import Kadena.Log.LogApi as X
import qualified Kadena.Types.Service.Evidence as Ev
import qualified Kadena.Types.Dispatch as Dispatch
import qualified Kadena.Types.Service.Commit as Commit
import Kadena.Types (startIndex, Dispatch, interval)

runLogService :: Dispatch
              -> (String -> IO())
              -> (Metric -> IO())
              -> FilePath
              -> KeySet
              -> IO ()
runLogService dispatch dbg publishMetric' dbPath keySet' = do
  dbConn' <- if not (null dbPath)
    then do
      dbg $ "[LogThread] Database Connection Opened: " ++ dbPath
      Just <$> createDB dbPath
    else do
      dbg "[LogThread] Persistence Disabled"
      return Nothing
  cryptoMvar <- newTVarIO Idle
  env <- return LogEnv
    { _logQueryChannel = dispatch ^. Dispatch.logService
    , _internalEvent = dispatch ^. Dispatch.internalEvent
    , _commitChannel = dispatch ^. Dispatch.commitService
    , _evidence = dispatch ^. Dispatch.evidence
    , _debugPrint = dbg
    , _keySet = keySet'
    , _persistedLogEntriesToKeepInMemory = 24000
    , _cryptoWorkerTVar = cryptoMvar
    , _dbConn = dbConn'
    , _publishMetric = publishMetric'
    }
  void (link <$> tinyCryptoWorker keySet' dbg (dispatch ^. Dispatch.logService) cryptoMvar)
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
  qr <- Map.fromList <$> mapM (\aq' -> evalQuery aq' >>= \res -> return $ (aq', res)) (Set.toList aq)
  liftIO $ putMVar mv qr
runQuery (Update ul) = do
  updateLogs ul
  updateEvidenceCache ul
  dbConn' <- view dbConn
  case dbConn' of
    Just conn -> do
      toPersist <- getUnpersisted
      case toPersist of
        Just logs -> do
          lsLastPersisted' <- return (_leLogIndex $ snd $ Map.findMax (logs ^. logEntries))
          lsLastPersisted .= lsLastPersisted'
          lsPersistedLogEntries %= plesAddNew logs
          lsVolatileLogEntries %= lesGetSection (Just $ lsLastPersisted' + 1) Nothing
          liftIO $ insertSeqLogEntry conn logs
          clearPersistedEntriesFromMemory
        Nothing -> return ()
    Nothing ->  return ()
runQuery (NeedCacheEvidence lis mv) = do
  qr <- buildNeedCacheEvidence lis
  liftIO $ putMVar mv qr
  debug $ "servicing cache miss pertaining to: " ++ show lis
runQuery (Tick t) = do
  t' <- liftIO $ pprintTock t
  debug t'
  volLEs <- use lsVolatileLogEntries
  perLes@(PersistedLogEntries _perLes') <- use lsPersistedLogEntries
  debug $ "Memory "
        ++ "{ V: " ++ show (lesCnt volLEs)
        ++ ", P: " ++ show (plesCnt perLes) ++ " }"

tinyCryptoWorker :: KeySet -> (String -> IO ()) -> LogServiceChannel -> TVar CryptoWorkerStatus -> IO (Async ())
tinyCryptoWorker ks dbg c mv = async $ forever $ do
  unverifiedLes <- atomically $ getWork mv
  stTime <- getCurrentTime
  !postVerify <- return $! verifySeqLogEntries ks unverifiedLes
  atomically $ writeTVar mv Idle
  writeComm c $ Update $ UpdateVerified $ VerifiedLogEntries postVerify
  endTime <- getCurrentTime
  dbg $ "[Service|Crypto]: processed " ++ show (Map.size (unverifiedLes ^. logEntries))
      ++ " in " ++ show (interval stTime endTime) ++ "mics"

getWork :: TVar CryptoWorkerStatus -> STM LogEntries
getWork t = do
  r <- readTVar t
  case r of
    Unprocessed v -> writeTVar t Processing >> return v
    Idle -> retry
    Processing -> error "CryptoWorker tried to get work but found the TVar Processing"

buildNeedCacheEvidence :: Set LogIndex -> LogThread (Map LogIndex ByteString)
buildNeedCacheEvidence lis = do
  let go li = maybe Nothing (\le -> Just $ (li,_leHash le)) <$> lookupEntry li
  Map.fromAscList . catMaybes <$> mapM go (Set.toAscList lis)
{-# INLINE buildNeedCacheEvidence #-}

updateEvidenceCache :: UpdateLogs -> LogThread ()
updateEvidenceCache (UpdateLastApplied _) = return ()
-- In these cases, we need to update the cache because we have something new
updateEvidenceCache (ULNew _) = updateEvidenceCache' >> tellTinyCryptoWorkerToDoMore
updateEvidenceCache (ULReplicate _) = updateEvidenceCache' >> tellTinyCryptoWorkerToDoMore
updateEvidenceCache (UpdateVerified _) = do
  tellKadenaToApplyLogEntries
  view cryptoWorkerTVar >>= liftIO . atomically . (`writeTVar` Idle) >> tellTinyCryptoWorkerToDoMore
updateEvidenceCache (ULCommitIdx _) =
  tellKadenaToApplyLogEntries

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
        , _lsLastCryptoVerified = _leLogIndex log'
        , _lsLastLogTerm = _leTerm log'
        }
    Nothing -> return initLogState

tellKadenaToApplyLogEntries :: LogThread ()
tellKadenaToApplyLogEntries = do
  mUnappliedEntries' <- getUnappliedEntries
  case mUnappliedEntries' of
    Just unappliedEntries' -> do
      (Just appliedIndex') <- return $ lesMaxIndex unappliedEntries'
      lsLastApplied .= appliedIndex'
      view commitChannel >>= liftIO . (`writeComm` Commit.CommitNewEntries unappliedEntries')
      debug $ "informing Kadena to apply up to: " ++ show appliedIndex'
      publishMetric' <- view publishMetric
      liftIO $ publishMetric' $ MetricCommitIndex appliedIndex'
    Nothing -> return ()

tellTinyCryptoWorkerToDoMore :: LogThread ()
tellTinyCryptoWorkerToDoMore = do
  mv <- view cryptoWorkerTVar
  unverifiedLes' <- getUnverifiedEntries
  case unverifiedLes' of
    Nothing -> return ()
    Just v -> do
      res <- liftIO $ atomically $ do
        r <- readTVar mv
        case r of
          Unprocessed _ -> writeTVar mv (Unprocessed v) >> return "Added more work the Crypto's TVar"
          Idle -> writeTVar mv (Unprocessed v) >> return "CryptoWorker was Idle, gave it something to do"
          Processing -> return "Crypto hasn't finished yet..."
      debug res

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
