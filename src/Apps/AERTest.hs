
module Apps.AERTest where

import Control.Concurrent.Chan.Unagi
import Control.Concurrent (newEmptyMVar)
import Control.Concurrent.Async
import Control.Lens

-- import Data.Map (Map)
import qualified Data.Map as Map
-- import Data.Set (Set)
import qualified Data.Set as Set

import Apps.Juno.Command
import Juno.Types
import qualified Juno.Types.Service.Log as Log
-- import qualified Juno.Types.Log as Log
import Juno.Spec.TestRig
-- import Juno.Types (CommandResult, initCommandMap)
-- import Juno.Types.Message.CMD (Command(..))

-- | Runs a 'Raft nt String String mt'.
runTest :: Int -> IO ()
runTest cnt = do
  stateVariable <- starterEnv
  let -- applyFn :: et -> IO rt
      applyFn :: Command -> IO CommandResult
      applyFn = runCommand stateVariable

  (leaderConfig, _clientConfig, (_privMap, _pubMap)) <- mkTestConfig 128

  leaderState' <- undefined
  dispatch <- initDispatch

  logStateSpy <- dupChan $ (\(Log.LogServiceChannel (i,_)) -> i) $ (dispatch ^. logService)

  juno <- async $ testJuno leaderConfig leaderState' dispatch applyFn
  link juno

  -- When the message to update CI comes down the pipe, our spy will catch it and finish the test
  returnWhenCommitIndexHits (cnt - 1) logStateSpy




returnWhenCommitIndexHits :: Int -> OutChan Log.QueryApi -> IO ()
returnWhenCommitIndexHits idx i = do
  q <- readChan i
  case q of
    (Log.Update (Log.ULCommitIdx (Log.UpdateCommitIndex idx'))) | idx' >= LogIndex idx -> return ()
    _ -> returnWhenCommitIndexHits idx i


leaderState :: NodeId -> IO RaftState
leaderState _nid = do
  mv <- newEmptyMVar
  return $ RaftState
    Leader   -- role
    (startTerm+1)  -- term
    Nothing    -- votedFor
    Nothing    -- lazyVote
    Nothing    -- currentLeader
    False      -- ignoreLeader
    Map.empty  -- commitProof
    Nothing    -- timerThread
    mv
    0          -- timeSinceLastAER
    Map.empty  -- replayMap
    Set.empty  -- cYesVotes
    Set.empty  -- cPotentialVotes
    Map.empty  -- lNextIndex
    Set.empty  -- lConvinced
    Nothing    -- lastCommitTime
    Map.empty  -- pendingRequests
    0          -- nextRequestId
    0          -- numTimeouts
