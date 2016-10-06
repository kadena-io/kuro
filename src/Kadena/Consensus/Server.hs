module Kadena.Consensus.Server
  ( runPrimedConsensusServer
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
import Kadena.Util.Util
import Kadena.Types.Service.Commit (ApplyFn)

import Kadena.Messaging.Turbine
import qualified Kadena.Messaging.Turbine as Turbine
import qualified Kadena.Service.Commit as Commit
import qualified Kadena.Service.Sender as Sender
import qualified Kadena.Log.Service as Log
import qualified Kadena.Service.Evidence as Ev

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
  -> (AppliedCommand -> IO ())
  -> IO (Async ())
launchCommitService dispatch' dbgPrint' publishMetric' keySet' nodeId' getTimestamp' applyFn' enqueueApplied' = do
  commitEnv <- return $! Commit.initCommitEnv dispatch' dbgPrint' applyFn' publishMetric' getTimestamp' enqueueApplied'
  link =<< async (Commit.runCommitService commitEnv nodeId' keySet')
  async $! foreverTick (_commitService dispatch') 1000000 Commit.Tick

launchLogService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> KeySet
  -> Config
  -> IO (Async ())
launchLogService dispatch' dbgPrint' publishMetric' keySet' rconf = do
  link =<< async (Log.runLogService dispatch' dbgPrint' publishMetric' (rconf ^. logSqlitePath) keySet')
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

runPrimedConsensusServer :: ReceiverEnv -> Config -> ConsensusSpec -> ConsensusState ->
                            IO UTCTime -> MVar PublishedConsensus -> ApplyFn -> IO ()
runPrimedConsensusServer renv rconf spec rstate timeCache' mPubConsensus' applyFn' = do
  let csize = 1 + Set.size (rconf ^. otherNodes)
      qsize = getQuorumSize csize
      publishMetric' = (spec ^. publishMetric)
      dispatch' = _dispatch renv
      dbgPrint' = Turbine._debugPrint renv
      getTimestamp' = spec ^. getTimestamp
      keySet' = Turbine._keySet renv
      nodeId' = rconf ^. nodeId
      enqueueApplied' = spec ^. enqueueApplied

  publishMetric' $ MetricClusterSize csize
  publishMetric' $ MetricAvailableSize csize
  publishMetric' $ MetricQuorumSize qsize
  void $ runMessageReceiver renv
  rconf' <- newIORef rconf
  timerTarget' <- return $ (rstate ^. timerTarget)
  -- EvidenceService Environment
  mEvState <- newEmptyMVar
  mLeaderNoFollowers <- newEmptyMVar

  link =<< launchSenderService dispatch' dbgPrint' publishMetric' mEvState rconf
  link =<< launchCommitService dispatch' dbgPrint' publishMetric' keySet' nodeId' getTimestamp' applyFn' enqueueApplied'
  link =<< launchEvidenceService dispatch' dbgPrint' publishMetric' mEvState rconf' mLeaderNoFollowers
  link =<< launchLogService dispatch' dbgPrint' publishMetric' keySet' rconf
  link =<< async (foreverTick (_internalEvent dispatch') 1000000 (InternalEvent . Tick))
  runRWS_
    raft
    (mkConsensusEnv rconf' csize qsize spec dispatch'
                    timerTarget' timeCache' mEvState mLeaderNoFollowers mPubConsensus')
    rstate

-- THREAD: SERVER MAIN
raft :: Consensus ()
raft = do
  la <- Log.hasQueryResult Log.LastApplied <$> queryLogs (Set.singleton Log.GetLastApplied)
  when (startIndex /= la) $ debug $ "Launch Sequence: disk sync replayed, Commit Index now " ++ show la
  logStaticMetrics
  resetElectionTimer
  handleEvents
