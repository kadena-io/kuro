{-# LANGUAGE RecordWildCards #-}
module Kadena.Consensus.Service
  ( runConsensusService
  ) where

import Control.Concurrent
import Control.Lens
import Control.Monad

import qualified Data.Set as Set
import Data.Thyme.Clock (UTCTime)

import System.FilePath

import qualified Pact.Types.SQLite as Pact
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
import qualified Kadena.PreProc.Service as PreProc
import qualified Kadena.History.Service as History
import qualified Kadena.HTTP.ApiServer as ApiServer

launchApiService
  :: Dispatch
  -> GlobalConfigTMVar
  -> (String -> IO ())
  -> MVar PublishedConsensus
  -> IO UTCTime
  -> IO ()
launchApiService dispatch' rconf' debugFn' mPubConsensus' getCurrentTime' = do
  apiPort' <- _apiPort . _gcConfig <$> readMVar rconf'
  linkAsyncTrack "ApiThread" (ApiServer.runApiServer dispatch' rconf' debugFn' apiPort' mPubConsensus' getCurrentTime')

launchHistoryService :: Dispatch
  -> (String -> IO ())
  -> IO UTCTime
  -> Config
  -> IO ()
launchHistoryService dispatch' dbgPrint' getTimestamp' rconf = do
  linkAsyncTrack "HistoryThread" (History.runHistoryService (History.initHistoryEnv dispatch' dbgPrint' getTimestamp' rconf) Nothing)
  linkAsyncTrack "HistoryHB" (foreverHeart (_historyChannel dispatch') 1000000 History.Heart)

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
  linkAsyncTrack "EvidenceHB" $ foreverHeart (_evidence dispatch') 1000000 Ev.Heart

launchCommitService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> KeySet
  -> NodeId
  -> IO UTCTime
  -> Pact.CommandConfig
  -> GlobalConfigTMVar
  -> IO ()
launchCommitService dispatch' dbgPrint' publishMetric' keySet' nodeId' getTimestamp' commandConfig' gcm' = do
  rconf' <- _gcConfig <$> readMVar gcm'
  commitEnv <- return $! Commit.initCommitEnv dispatch' dbgPrint' commandConfig' publishMetric' getTimestamp' (rconf' ^. enableWriteBehind) gcm'
  linkAsyncTrack "CommitThread" (Commit.runCommitService commitEnv nodeId' keySet')
  linkAsyncTrack "CommitHB" $ foreverHeart (_commitService dispatch') 1000000 Commit.Heart

launchLogService :: Dispatch
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> KeySet
  -> Config
  -> IO ()
launchLogService dispatch' dbgPrint' publishMetric' keySet' rconf = do
  linkAsyncTrack "LogThread" (Log.runLogService dispatch' dbgPrint' publishMetric' keySet' rconf)
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
        { _ccDbFile = if rconf ^. enablePersistence
                      then Just $ (rconf ^. logDir) </> (show $ _alias $ rconf ^. nodeId) ++ "-pact.sqlite"
                      else Nothing
        , _ccDebugFn = return . const () -- dbgPrint'
        , _ccEntity = rconf ^. entity.entName
        , _ccPragmas = Pact.fastNoJournalPragmas
        }

  publishMetric' $ MetricClusterSize csize
  publishMetric' $ MetricAvailableSize csize
  publishMetric' $ MetricQuorumSize qsize
  linkAsyncTrack "ReceiverThread" $ runMessageReceiver renv

  rconf' <- initGlobalConfigTMVar rconf
  timerTarget' <- return $ (rstate ^. timerTarget)
  -- EvidenceService Environment
  mEvState <- newEmptyMVar
  mLeaderNoFollowers <- newEmptyMVar

  launchHistoryService dispatch' dbgPrint' getTimestamp' rconf
  launchPreProcService dispatch' dbgPrint' getTimestamp' rconf
  launchSenderService dispatch' dbgPrint' publishMetric' mEvState mPubConsensus' rconf'
  launchCommitService dispatch' dbgPrint' publishMetric' keySet' nodeId' getTimestamp' commandConfig' rconf'
  launchEvidenceService dispatch' dbgPrint' publishMetric' mEvState rconf' mLeaderNoFollowers
  launchLogService dispatch' dbgPrint' publishMetric' keySet' rconf
  launchApiService dispatch' rconf' dbgPrint' mPubConsensus' getTimestamp'
  linkAsyncTrack "ConsensusHB" (foreverHeart (_internalEvent dispatch') 1000000 (InternalEvent . Heart))
  catchAndRethrow "ConsensusThread" $ runRWS_
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
