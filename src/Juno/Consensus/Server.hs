module Juno.Consensus.Server
  ( runRaftServer
  , runPrimedRaftServer
  ) where

import Control.Concurrent (newEmptyMVar)
import Control.Concurrent.Async
import qualified Control.Concurrent.Lifted as CL
import Control.Lens
import Control.Monad

import qualified Data.Set as Set
import Data.IORef
import Data.Thyme.Clock (UTCTime)

import Juno.Consensus.Api (apiReceiver)
import Juno.Consensus.Handle
import Juno.Consensus.Commit (applyLogEntries)
import Juno.Runtime.MessageReceiver
import qualified Juno.Runtime.MessageReceiver as RENV
import Juno.Runtime.Timer
import Juno.Types
import Juno.Util.Util

import qualified Juno.Service.Sender as Sender
import qualified Juno.Service.Log as Log
import qualified Juno.Service.Evidence as Ev

runPrimedRaftServer :: ReceiverEnv -> Config -> RaftSpec -> RaftState -> IO UTCTime -> IO ()
runPrimedRaftServer renv rconf spec rstate timeCache' = do
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
    (mkRaftEnv rconf' csize qsize spec (_dispatch renv) timerTarget' timeCache' mEvState mLeaderNoFollowers)
    rstate

runRaftServer :: ReceiverEnv -> Config -> RaftSpec -> IO UTCTime -> IO ()
runRaftServer renv rconf spec timeCache' = do
  timerTarget' <- newEmptyMVar
  runPrimedRaftServer renv rconf spec (initialRaftState timerTarget') timeCache'

-- THREAD: SERVER MAIN
raft :: Raft ()
raft = do
  debug "Launch Sequence: syncing logs from disk"
  mv <- queryLogs $ Set.singleton Log.GetUnappliedEntries
  res <- return $ Log.hasQueryResult Log.UnappliedEntries mv
  case res of
    Nothing -> return ()
    Just (commitIndex', unappliedEntries') -> applyLogEntries (Just unappliedEntries') commitIndex' -- This is for us replaying from disk, it will sync state before we launch
  la <- Log.hasQueryResult Log.LastApplied <$> (queryLogs $ Set.singleton Log.GetLastApplied)
  when (startIndex /= la) $ debug $ "Launch Sequence: disk sync replayed, Commit Index now " ++ show la
  logStaticMetrics
  void $ CL.fork apiReceiver     -- THREAD: waits for cmds from API, signs and sends to leader.
  resetElectionTimer
  handleEvents
