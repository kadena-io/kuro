{-# LANGUAGE BangPatterns #-}

module Kadena.Service.Log
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

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set



import Data.Thyme.Clock
import Database.SQLite.Simple (Connection(..))

import Kadena.Types.Comms
import Kadena.Types.Metric
import Kadena.Persistence.SQLite
import Kadena.Types.Service.Log as X
import qualified Kadena.Types.Service.Evidence as Ev
import qualified Kadena.Types.Dispatch as Dispatch
import Kadena.Types (startIndex, Event(ApplyLogEntries), Dispatch, interval)

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
    , _evidence = dispatch ^. Dispatch.evidence
    , _debugPrint = dbg
    , _keySet = keySet'
    , _cryptoWorkerTVar = cryptoMvar
    , _dbConn = dbConn'
    , _publishMetric = publishMetric'
    }
  void (link <$> tinyCryptoWorker keySet' dbg (dispatch ^. Dispatch.logService) cryptoMvar)
  initLogState' <- case dbConn' of
    Just conn' -> syncLogsFromDisk (dispatch ^. Dispatch.internalEvent) conn'
    Nothing -> return initLogState
  void $ runRWST handle env initLogState'

debug :: String -> LogThread ()
debug s = do
  dbg <- view debugPrint
  liftIO $ dbg $ "[Service|Log]: " ++ s

handle :: LogThread ()
handle = do
  oChan <- view logQueryChannel
  debug "launch!"
  forever $ do
    q <- liftIO $ readComm oChan
    runQuery q

runQuery :: QueryApi -> LogThread ()
runQuery (Query aq mv) = do
  a' <- get
  qr <- return $ Map.fromSet (`evalQuery` a') aq
  liftIO $ putMVar mv qr
runQuery (Update ul) = do
  modify (updateLogs ul)
  updateEvidenceCache ul
  dbConn' <- view dbConn
  case dbConn' of
    Just conn -> do
      toPersist <- getUnpersisted <$> get
      case toPersist of
        Just logs -> do
          lsLastPersisted' <- return (_leLogIndex $ snd $ Map.findMax (logs ^. logEntries))
          lsLastPersisted .= lsLastPersisted'
          lsPersistedLogEntries %= plesAddNew logs
          lsVolatileLogEntries %= lesGetSection (Just $ lsLastPersisted' + 1) Nothing
          liftIO $ insertSeqLogEntry conn logs
        Nothing -> return ()
    Nothing ->  return ()
runQuery (NeedCacheEvidence lis mv) = do
  qr <- buildNeedCacheEvidence lis <$> get
  liftIO $ putMVar mv qr
  debug $ "servicing cache miss pertaining to: " ++ show lis
runQuery (Tick t) = do
  t' <- liftIO $ pprintTock t
  debug t'

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

buildNeedCacheEvidence :: Set LogIndex -> LogState -> Map LogIndex ByteString
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

syncLogsFromDisk :: InternalEventChannel -> Connection -> IO LogState
syncLogsFromDisk internalEvent' conn = do
  logs@(LogEntries logs') <- selectAllLogEntries conn
  lastLog' <- return $ if Map.null logs' then Nothing else Just $ snd $ Map.findMax logs'
  case lastLog' of
    Just log' -> do
      liftIO $ writeComm internalEvent' $ InternalEvent $ ApplyLogEntries logs
      (Just minIdx) <- return $ lesMinIndex logs
      return LogState
        { _lsVolatileLogEntries = LogEntries Map.empty
        , _lsPersistedLogEntries = PersistedLogEntries $ Map.singleton minIdx logs
        , _lsLastApplied = startIndex
        , _lsLastLogIndex = _leLogIndex log'
        , _lsLastLogHash = _leHash log'
        , _lsNextLogIndex = _leLogIndex log' + 1
        , _lsCommitIndex = _leLogIndex log'
        , _lsLastPersisted = _leLogIndex log'
        , _lsLastCryptoVerified = _leLogIndex log'
        , _lsLastLogTerm = _leTerm log'
        }
    Nothing -> return initLogState

tellKadenaToApplyLogEntries :: LogThread ()
tellKadenaToApplyLogEntries = do
  es <- get
  case getUnappliedEntries es of
    Just unappliedEntries' -> do
      (Just appliedIndex') <- return $ lesMaxIndex unappliedEntries'
      lsLastApplied .= appliedIndex'
      view internalEvent >>= liftIO . (`writeComm` (InternalEvent $ ApplyLogEntries unappliedEntries'))
      debug $ "informing Kadena to apply up to: " ++ show appliedIndex'
      publishMetric' <- view publishMetric
      liftIO $ publishMetric' $ MetricCommitIndex appliedIndex'
    Nothing -> return ()

tellTinyCryptoWorkerToDoMore :: LogThread ()
tellTinyCryptoWorkerToDoMore = do
  mv <- view cryptoWorkerTVar
  es <- get
  unverifiedLes' <- return $! getUnverifiedEntries es
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
