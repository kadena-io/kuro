{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Types.Spec
  ( Raft
  , RaftSpec(..),ApplyFn
  , applyLogEntry , debugPrint, publishMetric, getTimestamp, random
  , viewConfig, readConfig, timerTarget, evidenceState, timeCache
  -- for API <-> Juno communication
  , dequeueFromApi ,cmdStatusMap, updateCmdMap
  , RaftEnv(..), cfg, enqueueLogQuery, clusterSize, quorumSize, rs
  , enqueue, enqueueMultiple, dequeue, enqueueLater, killEnqueued
  , sendMessage, clientSendMsg, mResetLeaderNoFollowers
  , informEvidenceServiceOfElection
  , RaftState(..), initialRaftState
  , nodeRole, term, votedFor, lazyVote, currentLeader, ignoreLeader
  , timerThread, replayMap, cYesVotes, cPotentialVotes, lastCommitTime, numTimeouts
  , pendingRequests, currentRequestId, timeSinceLastAER
  , Event(..)
  , mkRaftEnv
  ) where

-- timeSinceLastAER, lNextIndex, lConvinced, commitProof

import Control.Concurrent (MVar, ThreadId, killThread, yield, forkIO, threadDelay, tryPutMVar, tryTakeMVar, readMVar)
import Control.Lens hiding (Index, (|>))
import Control.Monad (when,void)
import Control.Monad.IO.Class
import Control.Monad.RWS.Strict (RWST)

import Data.IORef
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Thyme.Clock
import Data.Thyme.Time.Core ()
import System.Random (Random)

import Juno.Types.Base
import Juno.Types.Command
import Juno.Types.Config
import Juno.Types.Event
import Juno.Types.Message
import Juno.Types.Metric
import Juno.Types.Comms
import Juno.Types.Log
import Juno.Types.Dispatch
import Juno.Types.Service.Sender (SenderServiceChannel, ServiceRequest')
import Juno.Types.Service.Log (QueryApi(..))
import Juno.Types.Service.Evidence (PublishedEvidenceState, Evidence(ClearConvincedNodes))

type ApplyFn = LogEntry -> IO CommandResult

data RaftSpec = RaftSpec
  {
    -- ^ Function to apply a log entry to the state machine.
    _applyLogEntry    :: ApplyFn

    -- ^ Function to log a debug message (no newline).
  , _debugPrint       :: String -> IO ()

  , _publishMetric    :: Metric -> IO ()

  , _getTimestamp     :: IO UTCTime

  , _random           :: forall a . Random a => (a, a) -> IO a

  -- ^ How the API communicates with Raft, later could be redis w/e, etc.
  , _updateCmdMap     :: MVar CommandMap -> RequestId -> CommandStatus -> IO ()

  -- ^ Same mvar map as _updateCmdMVarMap needs to run in Raft m
  , _cmdStatusMap     :: CommandMVarMap

  , _dequeueFromApi   :: IO (RequestId, [(Maybe Alias, CommandEntry)])
  }
makeLenses (''RaftSpec)

data RaftState = RaftState
  { _nodeRole         :: Role
  , _term             :: Term
  , _votedFor         :: Maybe NodeId
  , _lazyVote         :: Maybe (Term, NodeId, LogIndex)
  , _currentLeader    :: Maybe NodeId
  , _ignoreLeader     :: Bool
  , _timerThread      :: Maybe ThreadId
  , _timerTarget      :: MVar Event
  , _replayMap        :: Map (NodeId, Signature) (Maybe CommandResult)
  , _cYesVotes        :: Set RequestVoteResponse
  , _cPotentialVotes  :: Set NodeId
  , _timeSinceLastAER :: Int
  -- used for metrics
  , _lastCommitTime   :: Maybe UTCTime
  -- used by clients
  , _pendingRequests  :: Map RequestId Command
  , _currentRequestId :: RequestId
  , _numTimeouts      :: Int
  }
makeLenses ''RaftState

initialRaftState :: MVar Event -> RaftState
initialRaftState timerTarget' = RaftState
{-role-}                Follower
{-term-}                startTerm
{-votedFor-}            Nothing
{-lazyVote-}            Nothing
{-currentLeader-}       Nothing
{-ignoreLeader-}        False
{-timerThread-}         Nothing
{-timerTarget-}         timerTarget'
{-replayMap-}           Map.empty
{-cYesVotes-}           Set.empty
{-cPotentialVotes-}     Set.empty
{-timeSinceLastAER-}    0
{-lastCommitTime-}      Nothing
{-pendingRequests-}     Map.empty
{-currentRequestId-}    0
{-numTimeouts-}         0

type Raft = RWST (RaftEnv) () RaftState IO

data RaftEnv = RaftEnv
  { _cfg              :: IORef Config
  , _enqueueLogQuery  :: QueryApi -> IO ()
  , _clusterSize      :: Int
  , _quorumSize       :: Int
  , _rs               :: RaftSpec
  , _sendMessage      :: ServiceRequest' -> IO ()
  , _enqueue          :: Event -> IO ()
  , _enqueueMultiple  :: [Event] -> IO ()
  , _enqueueLater     :: Int -> Event -> IO ThreadId
  , _killEnqueued     :: ThreadId -> IO ()
  , _dequeue          :: IO Event
  , _clientSendMsg    :: OutboundGeneral -> IO ()
  , _evidenceState    :: IO PublishedEvidenceState
  , _timeCache        :: IO UTCTime
  , _mResetLeaderNoFollowers :: MVar ResetLeaderNoFollowersTimeout
  , _informEvidenceServiceOfElection :: IO ()
  }
makeLenses ''RaftEnv

mkRaftEnv
  :: IORef Config
  -> Int
  -> Int
  -> RaftSpec
  -> Dispatch
  -> MVar Event
  -> (IO UTCTime)
  -> MVar PublishedEvidenceState
  -> MVar ResetLeaderNoFollowersTimeout
  -> RaftEnv
mkRaftEnv conf' cSize qSize rSpec dispatch timerTarget' timeCache' mEs mResetLeaderNoFollowers' = RaftEnv
    { _cfg = conf'
    , _enqueueLogQuery = writeComm ls'
    , _clusterSize = cSize
    , _quorumSize = qSize
    , _rs = rSpec
    , _sendMessage = sendMsg g'
    , _enqueue = writeComm ie' . InternalEvent
    , _enqueueMultiple = mapM_ (writeComm ie' . InternalEvent)
    , _enqueueLater = \t e -> do
        void $ tryTakeMVar timerTarget'
        -- We want to clear it the instance that we reset the timer.
        -- Not doing this can cause a bug when there's an AE being processed when the thread fires, causing a needless election.
        -- As there is a single producer for this mvar + the consumer is single threaded + fires this function this is safe.
        forkIO $ do
          threadDelay t
          b <- tryPutMVar timerTarget' e
          when (not b) (putStrLn "Failed to update timer MVar")
          -- TODO: what if it's already taken?
    , _killEnqueued = killThread
    , _dequeue = _unInternalEvent <$> readComm ie'
    , _clientSendMsg = writeComm cog'
    , _evidenceState = readMVar mEs
    , _timeCache = timeCache'
    , _mResetLeaderNoFollowers = mResetLeaderNoFollowers'
    , _informEvidenceServiceOfElection = writeComm ev' ClearConvincedNodes
    }
  where
    g' = dispatch ^. senderService
    cog' = dispatch ^. outboundGeneral
    ls' = dispatch ^. logService
    ie' = dispatch ^. internalEvent
    ev' = dispatch ^. evidence

sendMsg :: SenderServiceChannel -> ServiceRequest' -> IO ()
sendMsg outboxWrite og = do
  writeComm outboxWrite og
  yield

readConfig :: Raft Config
readConfig = view cfg >>= liftIO . readIORef

viewConfig :: Getting r Config r -> Raft r
viewConfig l = do
  (c :: Config) <- view cfg >>= liftIO . readIORef
  return $ view l c
