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

import qualified Kadena.Service.Sender as Sender
import qualified Kadena.Service.Log as Log
import qualified Kadena.Service.Evidence as Ev

runPrimedConsensusServer :: ReceiverEnv -> Config -> ConsensusSpec -> ConsensusState ->
                            IO UTCTime -> MVar PublishedConsensus -> IO ()
runPrimedConsensusServer renv rconf spec rstate timeCache' mPubConsensus' = do
  let csize = 1 + Set.size (rconf ^. otherNodes)
      qsize = getQuorumSize csize
  void $ runMessageReceiver renv
  rconf' <- newIORef rconf
  timerTarget' <- return $ (rstate ^. timerTarget)
  -- EvidenceService Environment
  mEvState <- newEmptyMVar
  mLeaderNoFollowers <- newEmptyMVar

  evEnv <- return $! Ev.initEvidenceEnv (_dispatch renv) (RENV._debugPrint renv) rconf' mEvState mLeaderNoFollowers

  link =<< (async $ Log.runLogService (_dispatch renv) (RENV._debugPrint renv) (rconf ^. logSqlitePath) (RENV._keySet renv))
  link =<< (async $ Sender.runSenderService (_dispatch renv) rconf (RENV._debugPrint renv) mEvState)
  link =<< (async $ Ev.runEvidenceService evEnv)
  -- This helps for testing, we'll send tocks every second to inflate the logs when we see weird pauses right before an election
  -- forever (writeComm (_internalEvent $ _dispatch renv) (InternalEvent $ Tock $ t) >> threadDelay 1000000)
  link =<< (async $ foreverTick (_internalEvent $ _dispatch renv) 1000000 (InternalEvent . Tick))
  link =<< (async $ foreverTick (_senderService $ _dispatch renv) 1000000 (Sender.Tick))
  link =<< (async $ foreverTick (_logService    $ _dispatch renv) 1000000 (Log.Tick))
  link =<< (async $ foreverTick (_evidence      $ _dispatch renv) 1000000 (Ev.Tick))
  runRWS_
    raft
    (mkConsensusEnv rconf' csize qsize spec (_dispatch renv)
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
