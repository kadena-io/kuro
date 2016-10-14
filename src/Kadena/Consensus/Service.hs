module Kadena.Consensus.Service
  ( runConsensusService
  ) where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Lens
import Control.Monad

import qualified Data.Set as Set
import Data.IORef
import Data.Thyme.Clock (UTCTime)

import Kadena.Consensus.Handle
import Kadena.Consensus.Util
import Kadena.Types
import Kadena.Commit.Types (ApplyFn)

import Kadena.Messaging.Turbine
import qualified Kadena.Messaging.Turbine as Turbine
import qualified Kadena.Commit.Service as Commit
import qualified Kadena.Sender.Service as Sender
import qualified Kadena.Log.Service as Log
import qualified Kadena.Evidence.Service as Ev
import qualified Kadena.History.Service as History

launchHistoryService :: Dispatch
  -> (String -> IO ())
  -> IO UTCTime
  -> Config
  -> IO (Async ())
launchHistoryService dispatch' dbgPrint' getTimestamp' rconf = do
  let dbPath' = rconf ^. logSqliteDir
  link =<< async (History.runHistoryService (History.initHistoryEnv dispatch' dbPath' dbgPrint' getTimestamp') Nothing)
  async (foreverTick (_historyChannel dispatch') 1000000 History.Tick)

launchEvidenceService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> MVar Ev.PublishedEvidenceState
  -> IORef Config
  -> MVar ResetLeaderNoFollowersTimeout
  -> IO (Async ())
launchEvidenceService dispatch' dbgPrint' publishMetric' mEvState rconf' mLeaderNoFollowers = do
  link =<< async (Ev.runEvidenceService $! Ev.initEvidenceEnv dispatch' dbgPrint' rconf' mEvState mLeaderNoFollowers publishMetric')
  async $ foreverTick (_evidence dispatch') 1000000 Ev.Tick

launchCommitService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> KeySet
  -> NodeId
  -> IO UTCTime
  -> ApplyFn
  -> IO (Async ())
launchCommitService dispatch' dbgPrint' publishMetric' keySet' nodeId' getTimestamp' applyFn' = do
  commitEnv <- return $! Commit.initCommitEnv dispatch' dbgPrint' applyFn' publishMetric' getTimestamp'
  link =<< async (Commit.runCommitService commitEnv nodeId' keySet')
  async $! foreverTick (_commitService dispatch') 1000000 Commit.Tick

launchLogService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> KeySet
  -> Config
  -> IO (Async ())
launchLogService dispatch' dbgPrint' publishMetric' keySet' rconf = do
  link =<< async (Log.runLogService dispatch' dbgPrint' publishMetric' (rconf ^. logSqliteDir) keySet')
  async (foreverTick (_logService dispatch') 1000000 Log.Tick)

launchSenderService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> MVar Ev.PublishedEvidenceState
  -> Config
  -> IO (Async ())
launchSenderService dispatch' dbgPrint' publishMetric' mEvState rconf = do
  link =<< async (Sender.runSenderService dispatch' rconf dbgPrint' publishMetric' mEvState)
  async $ foreverTick (_senderService dispatch') 1000000 Sender.Tick

runConsensusService :: ReceiverEnv -> Config -> ConsensusSpec -> ConsensusState ->
                            IO UTCTime -> MVar PublishedConsensus -> ApplyFn -> IO ()
runConsensusService renv rconf spec rstate timeCache' mPubConsensus' applyFn' = do
  let csize = 1 + Set.size (rconf ^. otherNodes)
      qsize = getQuorumSize csize
      publishMetric' = (spec ^. publishMetric)
      dispatch' = _dispatch renv
      dbgPrint' = Turbine._debugPrint renv
      getTimestamp' = spec ^. getTimestamp
      keySet' = Turbine._keySet renv
      nodeId' = rconf ^. nodeId

  publishMetric' $ MetricClusterSize csize
  publishMetric' $ MetricAvailableSize csize
  publishMetric' $ MetricQuorumSize qsize
  void $ runMessageReceiver renv
  rconf' <- newIORef rconf
  timerTarget' <- return $ (rstate ^. timerTarget)
  -- EvidenceService Environment
  mEvState <- newEmptyMVar
  mLeaderNoFollowers <- newEmptyMVar

  link =<< launchHistoryService dispatch' dbgPrint' getTimestamp' rconf
  link =<< launchSenderService dispatch' dbgPrint' publishMetric' mEvState rconf
  link =<< launchCommitService dispatch' dbgPrint' publishMetric' keySet' nodeId' getTimestamp' applyFn'
  link =<< launchEvidenceService dispatch' dbgPrint' publishMetric' mEvState rconf' mLeaderNoFollowers
  link =<< launchLogService dispatch' dbgPrint' publishMetric' keySet' rconf
  link =<< async (foreverTick (_internalEvent dispatch') 1000000 (InternalEvent . Tick))
  runRWS_
    kadena
    (mkConsensusEnv rconf' csize qsize spec dispatch'
                    timerTarget' timeCache' mEvState mLeaderNoFollowers mPubConsensus')
    rstate

-- THREAD: SERVER MAIN
kadena :: Consensus ()
kadena = do
  res <- queryLogs (Set.fromList [Log.GetLastApplied, Log.GetLastLogTerm])
  la <- return $! Log.hasQueryResult Log.LastApplied res
  lastValidElectionTerm .= Log.hasQueryResult Log.LastLogTerm res
  when (startIndex /= la) $ debug $ "Launch Sequence: disk sync replayed, Commit Index now " ++ show la
  logStaticMetrics
  resetElectionTimer
  handleEvents
