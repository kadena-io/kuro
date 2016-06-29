module Juno.Consensus.Server
  ( runRaftServer
  ) where

import Control.Lens
import qualified Data.Set as Set
import Data.IORef

import Juno.Consensus.Handle
import Juno.Consensus.Api (apiReceiver)
import Juno.Types
import Juno.Util.Util
import Juno.Runtime.Timer
import Juno.Runtime.MessageReceiver

import qualified Control.Concurrent.Lifted as CL
import Control.Monad

runRaftServer :: ReceiverEnv -> Config -> RaftSpec -> IO ()
runRaftServer renv rconf spec = do
  let csize = 1 + Set.size (rconf ^. otherNodes)
      qsize = getQuorumSize csize
  void $ runMessageReceiver renv
  rconf' <- newIORef rconf
  ls <- initLogState
  runRWS_
    raft
    (mkRaftEnv rconf' ls csize qsize spec (_dispatch renv))
    initialRaftState

-- THREAD: SERVER MAIN
raft :: Raft ()
raft = do
  logStaticMetrics
  void $ CL.fork apiReceiver     -- THREAD: waits for cmds from API, signs and sends to leader.
  resetElectionTimer
  handleEvents
