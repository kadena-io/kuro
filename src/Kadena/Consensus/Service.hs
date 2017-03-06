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

import qualified Pact.Types.Server as Pact
import Pact.Types.Server (CommandConfig(..))

import Kadena.Consensus.Handle
import Kadena.Consensus.Util
import Kadena.Types

import Kadena.Messaging.Turbine
import qualified Kadena.Messaging.Turbine as Turbine
import qualified Kadena.Commit.Service as Commit
import qualified Kadena.Sender.Service as Sender
import qualified Kadena.Log.Service as Log
import qualified Kadena.Evidence.Service as Ev
import qualified Kadena.History.Service as History
import qualified Kadena.HTTP.ApiServer as ApiServer

launchApiService
  :: Dispatch
  -> IORef Config
  -> (String -> IO ())
  -> MVar PublishedConsensus
  -> IO UTCTime
  -> IO (Async ())
launchApiService dispatch' rconf' debugFn' mPubConsensus' getCurrentTime' = do
  apiPort' <- _apiPort <$> readIORef rconf'
  async (ApiServer.runApiServer dispatch' rconf' debugFn' apiPort' mPubConsensus' getCurrentTime')

launchHistoryService :: Dispatch
  -> (String -> IO ())
  -> IO UTCTime
  -> Config
  -> IO (Async ())
launchHistoryService dispatch' dbgPrint' getTimestamp' rconf = do
  let dbPath' = rconf ^. logSqliteDir
  link =<< async (History.runHistoryService (History.initHistoryEnv dispatch' dbPath' dbgPrint' getTimestamp') Nothing)
  async (foreverHeart (_historyChannel dispatch') 1000000 History.Heart)

launchEvidenceService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> MVar Ev.PublishedEvidenceState
  -> IORef Config
  -> MVar ResetLeaderNoFollowersTimeout
  -> IO (Async ())
launchEvidenceService dispatch' dbgPrint' publishMetric' mEvState rconf' mLeaderNoFollowers = do
  link =<< async (Ev.runEvidenceService $! Ev.initEvidenceEnv dispatch' dbgPrint' rconf' mEvState mLeaderNoFollowers publishMetric')
  async $ foreverHeart (_evidence dispatch') 1000000 Ev.Heart

launchCommitService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> KeySet
  -> NodeId
  -> IO UTCTime
  -> Pact.CommandConfig
  -> IO (Async ())
launchCommitService dispatch' dbgPrint' publishMetric' keySet' nodeId' getTimestamp' commandConfig' = do
  commitEnv <- return $! Commit.initCommitEnv dispatch' dbgPrint' commandConfig' publishMetric' getTimestamp'
  link =<< async (Commit.runCommitService commitEnv nodeId' keySet')
  async $! foreverHeart (_commitService dispatch') 1000000 Commit.Heart

launchLogService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> KeySet
  -> Config
  -> IO (Async ())
launchLogService dispatch' dbgPrint' publishMetric' keySet' rconf = do
  link =<< async (Log.runLogService dispatch' dbgPrint' publishMetric' (rconf ^. logSqliteDir) keySet' (rconf ^. cryptoBatchSize))
  async (foreverHeart (_logService dispatch') 1000000 Log.Heart)

launchSenderService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> MVar Ev.PublishedEvidenceState
  -> Config
  -> IO (Async ())
launchSenderService dispatch' dbgPrint' publishMetric' mEvState rconf = do
  link =<< async (Sender.runSenderService dispatch' rconf dbgPrint' publishMetric' mEvState)
  async $ foreverHeart (_senderService dispatch') 1000000 Sender.Heart

runConsensusService :: ReceiverEnv -> Config -> ConsensusSpec -> ConsensusState ->
                            IO UTCTime -> MVar PublishedConsensus -> IO ()
runConsensusService renv rconf spec rstate timeCache' mPubConsensus' = do
  let csize = 1 + Set.size (rconf ^. otherNodes)
      qsize = getQuorumSize csize
      publishMetric' = (spec ^. publishMetric)
      dispatch' = _dispatch renv
      dbgPrint' = Turbine._debugPrint renv
      getTimestamp' = spec ^. getTimestamp
      keySet' = Turbine._keySet renv
      nodeId' = rconf ^. nodeId
      commandConfig' = CommandConfig
        { _ccDbFile = case rconf ^. logSqliteDir of
            -- TODO: fix this, it's terrible
            Just dbDir' -> Just (dbDir' ++ (show $ _alias nodeId') ++ "pact.sqlite")
            Nothing -> Nothing
        , _ccDebugFn = dbgPrint'
        , _ccEntity = rconf ^. entity.entName
        , _ccPragmas = []
        }

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
  link =<< launchCommitService dispatch' dbgPrint' publishMetric' keySet' nodeId' getTimestamp' commandConfig'
  link =<< launchEvidenceService dispatch' dbgPrint' publishMetric' mEvState rconf' mLeaderNoFollowers
  link =<< launchLogService dispatch' dbgPrint' publishMetric' keySet' rconf
  link =<< launchApiService dispatch' rconf' dbgPrint' mPubConsensus' getTimestamp'
  link =<< async (foreverHeart (_internalEvent dispatch') 1000000 (InternalEvent . Heart))
  runRWS_
    kadena
    (mkConsensusEnv rconf' csize qsize spec dispatch'
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
