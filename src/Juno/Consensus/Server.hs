module Juno.Consensus.Server
  ( runRaftServer
  ) where

import Control.Concurrent (newEmptyMVar)
import qualified Control.Concurrent.Lifted as CL
import Control.Lens
import Control.Monad

import qualified Data.Set as Set
import Data.IORef

import Juno.Consensus.Api (apiReceiver)
import Juno.Consensus.Handle
import Juno.Runtime.MessageReceiver
import Juno.Runtime.Timer
import Juno.Types
import Juno.Util.Util

runRaftServer :: ReceiverEnv -> Config -> RaftSpec -> IO ()
runRaftServer renv rconf spec = do
  let csize = 1 + Set.size (rconf ^. otherNodes)
      qsize = getQuorumSize csize
  void $ runMessageReceiver renv
  rconf' <- newIORef rconf
  timerTarget' <- newEmptyMVar
  ls <- initLogState
  runRWS_
    raft
    (mkRaftEnv rconf' ls csize qsize spec (_dispatch renv) timerTarget')
    (initialRaftState timerTarget')

-- THREAD: SERVER MAIN
raft :: Raft ()
raft = do
  logStaticMetrics
  void $ CL.fork apiReceiver     -- THREAD: waits for cmds from API, signs and sends to leader.
  resetElectionTimer
  handleEvents
