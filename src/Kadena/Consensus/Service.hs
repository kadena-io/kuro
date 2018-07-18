{-# LANGUAGE RecordWildCards #-}
module Kadena.Consensus.Service
  ( runConsensusService
  ) where

import Control.Concurrent
import Control.Lens
import Control.Monad

import qualified Data.Set as Set
import Data.Thyme.Clock (UTCTime)

import qualified Kadena.Config.ClusterMembership as CM
import Kadena.Config.TMVar
import Kadena.Consensus.Handle
import Kadena.Consensus.Util
import Kadena.Event (foreverHeart)
import Kadena.Types
import Kadena.Types.Entity
import Kadena.Types.KeySet

import Kadena.Messaging.Turbine
import qualified Kadena.Messaging.Turbine as Turbine
import qualified Kadena.Execution.Service as Exec
import qualified Kadena.Sender.Service as Sender
import qualified Kadena.Types.Log as Log
import qualified Kadena.Log.Types as Log
import qualified Kadena.Log.Service as Log
import qualified Kadena.Types.Evidence as Ev
import qualified Kadena.Evidence.Service as Ev
import qualified Kadena.PreProc.Service as PreProc
import qualified Kadena.History.Service as History
import qualified Kadena.HTTP.ApiServer as ApiServer
import Kadena.Consensus.Publish
import Kadena.Util.Util

launchApiService
  :: Dispatch
  -> GlobalConfigTMVar
  -> (String -> IO ())
  -> MVar PublishedConsensus
  -> IO UTCTime
  -> IO ()
launchApiService dispatch' rconf' debugFn' mPubConsensus' getCurrentTime' = do
  apiPort' <- _apiPort <$> readCurrentConfig rconf'
  linkAsyncTrack "ApiThread" (ApiServer.runApiServer dispatch' rconf' debugFn' apiPort' mPubConsensus' getCurrentTime')

launchHistoryService :: Dispatch
  -> (String -> IO ())
  -> IO UTCTime
  -> Config
  -> IO ()
launchHistoryService dispatch' dbgPrint' getTimestamp' rconf = do
  linkAsyncTrack "HistoryThread" (History.runHistoryService (History.initHistoryEnv dispatch' dbgPrint' getTimestamp' rconf) Nothing)
  linkAsyncTrack "HistoryHB" (foreverHeart (_historyChannel dispatch') 1000000 HistoryBeat)

launchPreProcService :: Dispatch
  -> (String -> IO ())
  -> IO UTCTime
  -> Config
  -> IO ()
launchPreProcService dispatch' dbgPrint' getTimestamp' Config{..} = do
  linkAsyncTrack "PreProcThread" (PreProc.runPreProcService (PreProc.initPreProcEnv dispatch' _preProcThreadCount dbgPrint' getTimestamp' _preProcUsePar))
  linkAsyncTrack "PreProcHB" (foreverHeart (_processRequestChannel dispatch') 1000000 PreProc.Heart)

launchEvidenceService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> MVar Ev.PublishedEvidenceState
  -> GlobalConfigTMVar
  -> MVar ResetLeaderNoFollowersTimeout
  -> IO ()
launchEvidenceService dispatch' dbgPrint' publishMetric' mEvState rconf' mLeaderNoFollowers = do
  linkAsyncTrack "EvidenceThread" (Ev.runEvidenceService $! Ev.initEvidenceEnv dispatch' dbgPrint' rconf' mEvState mLeaderNoFollowers publishMetric')
  linkAsyncTrack "EvidenceHB" $ foreverHeart (_evidence dispatch') 1000000 EvidenceBeat

launchExecutionService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> KeySet
  -> NodeId
  -> IO UTCTime
  -> GlobalConfigTMVar
  -> MVar PublishedConsensus
  -> EntityConfig
  -> IO ()
launchExecutionService dispatch' dbgPrint' publishMetric' keySet' nodeId' getTimestamp' gcm' pubConsensus ent = do
  rconf' <- readCurrentConfig gcm'
  execEnv <- return $! Exec.initExecutionEnv
    dispatch' dbgPrint' (_pactPersist rconf')
      (_logRules rconf') publishMetric' getTimestamp' gcm' ent
  pub <- return $! Publish pubConsensus dispatch' getTimestamp' nodeId'
  linkAsyncTrack "ExecutionThread" (Exec.runExecutionService execEnv pub nodeId' keySet')
  linkAsyncTrack "ExecutionHB" $ foreverHeart (_execService dispatch') 1000000 Exec.Heart

launchLogService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> Config
  -> IO ()
launchLogService dispatch' dbgPrint' publishMetric' rconf = do
  linkAsyncTrack "LogThread" (Log.runLogService dispatch' dbgPrint' publishMetric' rconf)
  linkAsyncTrack "LogHB" $ (foreverHeart (_logService dispatch') 1000000 Log.Heart)

launchSenderService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> MVar Ev.PublishedEvidenceState
  -> MVar PublishedConsensus
  -> GlobalConfigTMVar
  -> IO ()
launchSenderService dispatch' dbgPrint' publishMetric' mEvState mPubCons rconf = do
  linkAsyncTrack "SenderThread" (Sender.runSenderService dispatch' rconf dbgPrint' publishMetric' mEvState mPubCons)
  linkAsyncTrack "SenderHB" $ foreverHeart (_senderService dispatch') 1000000 Sender.Heart

runConsensusService :: ReceiverEnv -> GlobalConfigTMVar -> ConsensusSpec -> ConsensusState ->
                            IO UTCTime -> MVar PublishedConsensus -> IO ()
runConsensusService renv gcm spec rstate timeCache' mPubConsensus' = do
  rconf <- readCurrentConfig gcm
  let members = rconf ^. clusterMembers
      csize = 1 + CM.countOthers members
      qsize = CM.minQuorumOthers members
      changeToSize = CM.countTransitional members
      changeToQuorum = CM.minQuorumTransitional members
      publishMetric' = (spec ^. publishMetric)
      dispatch' = _dispatch renv
      dbgPrint' = Turbine._debugPrint renv
      getTimestamp' = spec ^. getTimestamp
      keySet' = Turbine._keySet renv
      nodeId' = rconf ^. nodeId

  publishMetric' $ MetricClusterSize csize
  publishMetric' $ MetricAvailableSize csize
  publishMetric' $ MetricQuorumSize qsize
  publishMetric' $ MetricChangeToClusterSize changeToSize
  publishMetric' $ MetricChangeToQuorumSize changeToQuorum
  linkAsyncTrack "ReceiverThread" $ runMessageReceiver renv

  timerTarget' <- return $ (rstate ^. csTimerTarget)
  -- EvidenceService Environment
  mEvState <- newEmptyMVar
  mLeaderNoFollowers <- newEmptyMVar

  launchHistoryService dispatch' dbgPrint' getTimestamp' rconf
  launchPreProcService dispatch' dbgPrint' getTimestamp' rconf
  launchSenderService dispatch' dbgPrint' publishMetric' mEvState mPubConsensus' gcm
  launchExecutionService dispatch' dbgPrint' publishMetric' keySet' nodeId' getTimestamp' gcm mPubConsensus' (_entity rconf)
  launchEvidenceService dispatch' dbgPrint' publishMetric' mEvState gcm mLeaderNoFollowers
  launchLogService dispatch' dbgPrint' publishMetric' rconf
  launchApiService dispatch' gcm dbgPrint' mPubConsensus' getTimestamp'
  linkAsyncTrack "ConsensusHB" (foreverHeart (_consensusEvent dispatch') 1000000 (ConsensusEvent . Heart))
  catchAndRethrow "ConsensusThread" $ runRWS_
    kadena
    (mkConsensusEnv gcm spec dispatch'
                    timerTarget' timeCache' mEvState mLeaderNoFollowers mPubConsensus')
    rstate

-- THREAD: SERVER MAIN
kadena :: Consensus ()
kadena = do
  la <- Log.hasQueryResult Log.LastApplied <$> queryLogs (Set.singleton Log.GetLastApplied)
  when (startIndex /= la) $ debug $ "Launch Sequence: disk sync replayed, Commit Index now " ++ show la
  logStaticMetrics
  resetElectionTimer
  handleEvents
