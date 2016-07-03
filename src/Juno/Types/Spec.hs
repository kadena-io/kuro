{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Types.Spec
  ( Raft
  , RaftSpec(..)
  , readLogEntry, writeLogEntry, readTermNumber, writeTermNumber
  , readVotedFor, writeVotedFor, applyLogEntry
  , debugPrint, publishMetric, getTimestamp, random
  , viewConfig, readConfig, timerTarget
  -- for API <-> Juno communication
  , dequeueFromApi ,cmdStatusMap, updateCmdMap
  , RaftEnv(..), cfg, logThread, clusterSize, quorumSize, rs
  , enqueue, enqueueMultiple, dequeue, enqueueLater, killEnqueued
  , sendMessage, sendMessages, sendAerRvRvrMessage
  , RaftState(..), nodeRole, term, votedFor, lazyVote, currentLeader, ignoreLeader
  , logEntries, commitIndex, commitProof, lastApplied, timerThread, replayMap
  , cYesVotes, cPotentialVotes, lNextIndex, lMatchIndex, lConvinced
  , lastCommitTime, numTimeouts, pendingRequests, currentRequestId
  , timeSinceLastAER
  , initialRaftState
  , Event(..)
  , mkRaftEnv
  ) where

import Control.Concurrent (MVar, ThreadId, killThread, yield, forkIO, threadDelay, tryPutMVar, tryTakeMVar)
import Control.Lens hiding (Index, (|>))
import Control.Monad (when)
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
import Juno.Types.Log
import Juno.Types.Message
import Juno.Types.Metric
import Juno.Types.Comms

-- | A structure containing all the implementation details for running
-- the raft protocol.
-- Types:
-- nt -- "node type", ie identifier (host/port, topic, subject)
-- et -- "entry type", serialized format for submissions into Raft
-- rt -- "return type", serialized format for "results" or "responses"
-- mt -- "message type", serialized format for sending over wire
data RaftSpec = RaftSpec
  {
    -- ^ Function to get a log entry from persistent storage.
    _readLogEntry     :: LogIndex -> IO (Maybe CommandEntry)

    -- ^ Function to write a log entry to persistent storage.
  , _writeLogEntry    :: LogIndex -> (Term,CommandEntry) -> IO ()

    -- ^ Function to get the term number from persistent storage.
  , _readTermNumber   :: IO Term

    -- ^ Function to write the term number to persistent storage.
  , _writeTermNumber  :: Term -> IO ()

    -- ^ Function to read the node voted for from persistent storage.
  , _readVotedFor     :: IO (Maybe NodeId)

    -- ^ Function to write the node voted for to persistent storage.
  , _writeVotedFor    :: Maybe NodeId -> IO ()

    -- ^ Function to apply a log entry to the state machine.
  , _applyLogEntry    :: Command -> IO CommandResult

    -- ^ Function to log a debug message (no newline).
  , _debugPrint       :: NodeId -> String -> IO ()

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
  { _nodeRole             :: Role
  , _term             :: Term
  , _votedFor         :: Maybe NodeId
  , _lazyVote         :: Maybe (Term, NodeId, LogIndex)
  , _currentLeader    :: Maybe NodeId
  , _ignoreLeader     :: Bool
  , _commitProof      :: Map NodeId AppendEntriesResponse
  , _timerThread      :: Maybe ThreadId
  , _timerTarget      :: MVar Event
  , _timeSinceLastAER :: Int
  , _replayMap        :: Map (NodeId, Signature) (Maybe CommandResult)
  , _cYesVotes        :: Set RequestVoteResponse
  , _cPotentialVotes  :: Set NodeId
  , _lNextIndex       :: Map NodeId LogIndex
  , _lMatchIndex      :: Map NodeId LogIndex
  , _lConvinced       :: Set NodeId
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
  Follower   -- role
  startTerm  -- term
  Nothing    -- votedFor
  Nothing    -- lazyVote
  Nothing    -- currentLeader
  False      -- ignoreLeader
  Map.empty  -- commitProof
  Nothing    -- timerThread
  timerTarget'
  0          -- timeSinceLastAER
  Map.empty  -- replayMap
  Set.empty  -- cYesVotes
  Set.empty  -- cPotentialVotes
  Map.empty  -- lNextIndex
  Map.empty  -- lMatchIndex
  Set.empty  -- lConvinced
  Nothing    -- lastCommitTime
  Map.empty  -- pendingRequests
  0          -- nextRequestId
  0          -- numTimeouts

type Raft = RWST (RaftEnv) () RaftState IO

data RaftEnv = RaftEnv
  { _cfg              :: IORef Config
  , _logThread        :: IORef (LogState LogEntry)
  , _clusterSize      :: Int
  , _quorumSize       :: Int
  , _rs               :: RaftSpec
  , _sendMessage      :: OutboundGeneral -> IO ()
  , _sendMessages     :: [OutboundGeneral] -> IO ()
  , _sendAerRvRvrMessage :: OutboundAerRvRvr -> IO ()
  , _enqueue          :: Event -> IO ()
  , _enqueueMultiple  :: [Event] -> IO ()
  , _enqueueLater     :: Int -> Event -> IO ThreadId
  , _killEnqueued     :: ThreadId -> IO ()
  , _dequeue          :: IO Event
  }
makeLenses ''RaftEnv

mkRaftEnv :: IORef Config -> IORef (LogState LogEntry) -> Int -> Int -> RaftSpec -> Dispatch -> MVar Event -> RaftEnv
mkRaftEnv conf' log' cSize qSize rSpec dispatch timerTarget' = RaftEnv
    { _cfg = conf'
    , _logThread = log'
    , _clusterSize = cSize
    , _quorumSize = qSize
    , _rs = rSpec
    , _sendMessage = sendMsg g'
    , _sendMessages = sendMsgs g'
    , _sendAerRvRvrMessage = sendAerRvRvrMsg a'
    , _enqueue = writeComm ie' . InternalEvent
    , _enqueueMultiple = mapM_ (writeComm ie' . InternalEvent)
    , _enqueueLater = \t e -> forkIO (do
                                     -- We want to clear it the instance that we reset the timer.
                                     -- Not doing this can cause a bug when there's an AE being processed when the thread fires, causing a needless election.
                                     -- As there is a single producer for this mvar + the consumer is single threaded + fires this function this is safe.
                                     _ <- tryTakeMVar timerTarget'
                                     threadDelay t
                                     b <- tryPutMVar timerTarget' e
                                     when (not b) (putStrLn "Failed to update timer MVar")
                                     writeComm ie' (InternalEvent Tock)
                                     ) -- TODO: what if it's already taken?
    , _killEnqueued = killThread
    , _dequeue = _unInternalEvent <$> readComm ie'
    }
  where
    g' = dispatch ^. outboundGeneral
    a' = dispatch ^. outboundAerRvRvr
    ie' = dispatch ^. internalEvent

sendMsgs :: OutboundGeneralChannel -> [OutboundGeneral] -> IO ()
sendMsgs outboxWrite ogs = do
  mapM_ (writeComm outboxWrite) ogs
  yield

sendMsg :: OutboundGeneralChannel -> OutboundGeneral -> IO ()
sendMsg outboxWrite og = do
  writeComm outboxWrite og
  yield

sendAerRvRvrMsg :: OutboundAerRvRvrChannel -> OutboundAerRvRvr -> IO ()
sendAerRvRvrMsg outboxWrite og = do
  writeComm outboxWrite og
  yield

readConfig :: Raft Config
readConfig = view cfg >>= liftIO . readIORef

viewConfig :: Getting r Config r -> Raft r
viewConfig l = do
  (c :: Config) <- view cfg >>= liftIO . readIORef
  return $ view l c
