{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Types.Spec
  ( Raft
  , RaftSpec(..)
  , readLogEntry, writeLogEntry, readTermNumber, writeTermNumber
  , readVotedFor, writeVotedFor, applyLogEntry, sendMessage
  , sendMessages, getMessage, getMessages, getNewCommands, getNewEvidence, getRvAndRVRs
  , debugPrint, publishMetric, getTimestamp, random
  , enqueue, enqueueMultiple, dequeue, enqueueLater, killEnqueued
  -- for API <-> Juno communication
  , dequeueFromApi ,cmdStatusMap, updateCmdMap
  , RaftEnv(..), cfg, clusterSize, quorumSize, rs
  , RaftState(..), nodeRole, term, votedFor, lazyVote, currentLeader, ignoreLeader
  , logEntries, commitIndex, commitProof, lastApplied, timerThread, replayMap
  , cYesVotes, cPotentialVotes, lNextIndex, lMatchIndex, lConvinced
  , lastCommitTime, numTimeouts, pendingRequests, currentRequestId
  , timeSinceLastAER, lLastBatchUpdate
  , initialRaftState
  , Event(..)
  ) where

import Control.Concurrent (MVar, ThreadId)
import Control.Lens hiding (Index, (|>))
import Control.Monad.RWS.Strict (RWST)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.ByteString (ByteString)
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

    -- ^ Function to send a message to a node.
  , _sendMessage      :: NodeId -> ByteString -> IO ()

    -- ^ Send more than one message at once
  , _sendMessages     :: [(NodeId,ByteString)] -> IO ()

    -- ^ Function to get the next message.
  , _getMessage       :: IO (ReceivedAt, SignedRPC)

    -- ^ Function to get the next N SignedRPCs not of type CMD, CMDB, or AER
  , _getMessages   :: Int -> IO [(ReceivedAt, SignedRPC)]

    -- ^ Function to get the next N SignedRPCs of type CMD or CMDB
  , _getNewCommands   :: Int -> IO [(ReceivedAt, SignedRPC)]

    -- ^ Function to get the next N SignedRPCs of type AER
  , _getNewEvidence   :: Int -> IO [(ReceivedAt, SignedRPC)]

    -- ^ Function to get the next RV or RVR
  , _getRvAndRVRs     :: IO (ReceivedAt, SignedRPC)

    -- ^ Function to log a debug message (no newline).
  , _debugPrint       :: NodeId -> String -> IO ()

  , _publishMetric    :: Metric -> IO ()

  , _getTimestamp     :: IO UTCTime

  , _random           :: forall a . Random a => (a, a) -> IO a

  , _enqueue          :: Event -> IO ()

  , _enqueueMultiple  :: [Event] -> IO ()

  , _enqueueLater     :: Int -> Event -> IO ThreadId

  , _killEnqueued     :: ThreadId -> IO ()

  , _dequeue          :: IO Event

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
  , _logEntries       :: Log LogEntry
  , _commitIndex      :: LogIndex
  , _lastApplied      :: LogIndex
  , _commitProof      :: Map NodeId AppendEntriesResponse
  , _timerThread      :: Maybe ThreadId
  , _timeSinceLastAER :: Int
  , _replayMap        :: Map (NodeId, Signature) (Maybe CommandResult)
  , _cYesVotes        :: Set RequestVoteResponse
  , _cPotentialVotes  :: Set NodeId
  , _lNextIndex       :: Map NodeId LogIndex
  , _lMatchIndex      :: Map NodeId LogIndex
  , _lConvinced       :: Set NodeId
  , _lLastBatchUpdate :: (UTCTime, Maybe ByteString)
  -- used for metrics
  , _lastCommitTime   :: Maybe UTCTime
  -- used by clients
  , _pendingRequests  :: Map RequestId Command
  , _currentRequestId :: RequestId
  , _numTimeouts      :: Int
  }
makeLenses ''RaftState

initialRaftState :: RaftState
initialRaftState = RaftState
  Follower   -- role
  startTerm  -- term
  Nothing    -- votedFor
  Nothing    -- lazyVote
  Nothing    -- currentLeader
  False      -- ignoreLeader
  mempty     -- log
  startIndex -- commitIndex
  startIndex -- lastApplied
  Map.empty  -- commitProof
  Nothing    -- timerThread
  0          -- timeSinceLastAER
  Map.empty  -- replayMap
  Set.empty  -- cYesVotes
  Set.empty  -- cPotentialVotes
  Map.empty  -- lNextIndex
  Map.empty  -- lMatchIndex
  Set.empty  -- lConvinced
  (minBound, Nothing)   -- lLastBatchUpdate (when we start up, we want batching to fire immediately)
  Nothing    -- lastCommitTime
  Map.empty  -- pendingRequests
  0          -- nextRequestId
  0          -- numTimeouts

type Raft = RWST (RaftEnv) () RaftState IO

data RaftEnv = RaftEnv
  { _cfg         :: Config
  , _clusterSize :: Int
  , _quorumSize  :: Int
  , _rs          :: RaftSpec
  }
makeLenses ''RaftEnv
