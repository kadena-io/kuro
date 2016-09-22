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
import Kadena.Runtime.MessageReceiver
import qualified Kadena.Runtime.MessageReceiver as RENV
import Kadena.Runtime.Timer
import Kadena.Types
import Kadena.Util.Util
import Kadena.Types.Service.Commit (ApplyFn)

import qualified Kadena.Service.Commit as Commit
import qualified Kadena.Service.Sender as Sender
import qualified Kadena.Service.Log as Log
import qualified Kadena.Service.Evidence as Ev


runPrimedConsensusServer :: ReceiverEnv -> Config -> ConsensusSpec -> ConsensusState ->
                            IO UTCTime -> MVar PublishedConsensus -> ApplyFn -> IO ()
runPrimedConsensusServer renv rconf spec rstate timeCache' mPubConsensus' applyFn' = do
  let csize = 1 + Set.size (rconf ^. otherNodes)
      qsize = getQuorumSize csize
      publishMetric' = (spec ^. publishMetric)
      dispatch' = _dispatch renv
      dbgPrint' = RENV._debugPrint renv
      getTimestamp' = spec ^. getTimestamp
      keySet' = RENV._keySet renv
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

  evEnv <- return $! Ev.initEvidenceEnv dispatch' dbgPrint' rconf' mEvState mLeaderNoFollowers publishMetric'
  commitEnv <- return $! Commit.initCommitEnv dispatch' dbgPrint' applyFn' publishMetric' getTimestamp' (spec ^. enqueueApplied)

  link =<< (async $ Log.runLogService dispatch' dbgPrint' publishMetric' (rconf ^. logSqlitePath) keySet')
  link =<< (async $ Sender.runSenderService dispatch' rconf dbgPrint' publishMetric' mEvState)
  link =<< (async $ Ev.runEvidenceService evEnv)
  link =<< (async $ Commit.runCommitService commitEnv nodeId' keySet')
  -- This helps for testing, we'll send tocks every second to inflate the logs when we see weird pauses right before an election
  -- forever (writeComm (_internalEvent $ _dispatch renv) (InternalEvent $ Tock $ t) >> threadDelay 1000000)
  link =<< (async $ foreverTick (_internalEvent dispatch') 1000000 (InternalEvent . Tick))
  link =<< (async $ foreverTick (_senderService dispatch') 1000000 Sender.Tick)
  link =<< (async $ foreverTick (_logService    dispatch') 1000000 Log.Tick)
  link =<< (async $ foreverTick (_evidence      dispatch') 1000000 Ev.Tick)
  link =<< (async $ foreverTick (_commitService dispatch') 1000000 Commit.Tick)
  runRWS_
    raft
    (mkConsensusEnv rconf' csize qsize spec dispatch'
                    timerTarget' timeCache' mEvState mLeaderNoFollowers mPubConsensus')
    rstate

-- THREAD: SERVER MAIN
raft :: Consensus ()
raft = do
  la <- Log.hasQueryResult Log.LastApplied <$> (queryLogs $ Set.singleton Log.GetLastApplied)
  when (startIndex /= la) $ debug $ "Launch Sequence: disk sync replayed, Commit Index now " ++ show la
  logStaticMetrics
  resetElectionTimer
  handleEvents
