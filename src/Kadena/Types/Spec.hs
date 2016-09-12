{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Spec
  ( Consensus
  , ConsensusSpec(..),ApplyFn
  , applyLogEntry , debugPrint, publishMetric, getTimestamp, random
  , viewConfig, readConfig, timerTarget, evidenceState, timeCache
  -- for API <-> Kadena communication
  , enqueueApplied
  , ConsensusEnv(..), cfg, enqueueLogQuery, clusterSize, quorumSize, rs
  , enqueue, enqueueMultiple, dequeue, enqueueLater, killEnqueued
  , sendMessage, clientSendMsg, mResetLeaderNoFollowers, mPubConsensus
  , informEvidenceServiceOfElection
  , ConsensusState(..), initialConsensusState
  , nodeRole, term, votedFor, lazyVote, currentLeader, ignoreLeader
  , timerThread, replayMap, cYesVotes, cPotentialVotes, lastCommitTime
  , timeSinceLastAER, cmdBloomFilter, invalidCandidateResults
  , Event(..)
  , mkConsensusEnv
  , PublishedConsensus(..),pcLeader,pcRole,pcTerm
  , LazyVote(..), lvVoteFor, lvAllReceived
  , InvalidCandidateResults(..), icrMyReqVoteSig, icrNoVotes
  ) where

-- timeSinceLastAER, lNextIndex, lConvinced, commitProof

import Control.Concurrent (MVar, ThreadId, killThread, yield, forkIO, threadDelay, tryPutMVar, tryTakeMVar, readMVar)
import Control.Lens hiding (Index, (|>))
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.RWS.Strict (RWST)

import Data.BloomFilter (Bloom)
import qualified Data.BloomFilter as Bloom
import qualified Data.BloomFilter.Hash as BHashes
import Data.IORef
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Thyme.Clock
import Data.Thyme.Time.Core ()
import System.Random (Random)

import Kadena.Types.Base
import Kadena.Types.Command
import Kadena.Types.Config
import Kadena.Types.Event
import Kadena.Types.Message
import Kadena.Types.Metric
import Kadena.Types.Comms
import Kadena.Types.Log
import Kadena.Types.Dispatch
import Kadena.Types.Service.Sender (SenderServiceChannel, ServiceRequest')
import Kadena.Types.Service.Log (QueryApi(..))
import Kadena.Types.Service.Evidence (PublishedEvidenceState, Evidence(ClearConvincedNodes))

type ApplyFn = LogEntry -> IO CommandResult

data PublishedConsensus = PublishedConsensus
    {
      _pcLeader :: Maybe NodeId
    , _pcRole :: Role
    , _pcTerm :: Term
    }
makeLenses ''PublishedConsensus

data ConsensusSpec = ConsensusSpec
  {
    -- ^ Function to apply a log entry to the state machine.
    _applyLogEntry    :: !ApplyFn

    -- ^ Function to log a debug message (no newline).
  , _debugPrint       :: !(String -> IO ())

  , _publishMetric    :: !(Metric -> IO ())

  , _getTimestamp     :: !(IO UTCTime)

  , _random           :: !(forall a . Random a => (a, a) -> IO a)

  , _enqueueApplied   :: !(AppliedCommand -> IO ())

  }
makeLenses (''ConsensusSpec)

data InvalidCandidateResults = InvalidCandidateResults
  { _icrMyReqVoteSig :: !Signature
  , _icrNoVotes :: !(Set NodeId)
  } deriving (Show, Eq)
makeLenses ''InvalidCandidateResults

data LazyVote = LazyVote
  { _lvVoteFor :: !RequestVote
  , _lvAllReceived :: !(Map NodeId RequestVote)
  } deriving (Show, Eq)
makeLenses ''LazyVote

data ConsensusState = ConsensusState
  { _nodeRole         :: !Role
  , _term             :: !Term
  , _votedFor         :: !(Maybe NodeId)
  , _lazyVote         :: !(Maybe LazyVote)
  , _currentLeader    :: !(Maybe NodeId)
  , _ignoreLeader     :: !Bool
  , _timerThread      :: !(Maybe ThreadId)
  , _timerTarget      :: !(MVar Event)
  , _replayMap        :: !(Map (NodeId, Signature) (Maybe CommandResult))
  , _cmdBloomFilter   :: !(Bloom (NodeId, Signature))
  , _cYesVotes        :: !(Set RequestVoteResponse)
  , _cPotentialVotes  :: !(Set NodeId)
  , _timeSinceLastAER :: !Int
  -- used for metrics
  , _lastCommitTime   :: !(Maybe UTCTime)
  -- used only during Candidate State
  , _invalidCandidateResults :: !(Maybe InvalidCandidateResults)
  }
makeLenses ''ConsensusState

initialConsensusState :: MVar Event -> ConsensusState
initialConsensusState timerTarget' = ConsensusState
{-role-}                Follower
{-term-}                startTerm
{-votedFor-}            Nothing
{-lazyVote-}            Nothing
{-currentLeader-}       Nothing
{-ignoreLeader-}        False
{-timerThread-}         Nothing
{-timerTarget-}         timerTarget'
{-replayMap-}           Map.empty
{-cmdBloomFilter-}      (Bloom.empty (\(n,Sig s) -> BHashes.cheapHashes 3 (_fullAddr n, s)) 536870912)
{-cYesVotes-}           Set.empty
{-cPotentialVotes-}     Set.empty
{-timeSinceLastAER-}    0
{-lastCommitTime-}      Nothing
{-invalidCandidateResults-} Nothing

type Consensus = RWST ConsensusEnv () ConsensusState IO

data ConsensusEnv = ConsensusEnv
  { _cfg              :: !(IORef Config)
  , _enqueueLogQuery  :: !(QueryApi -> IO ())
  , _clusterSize      :: !Int
  , _quorumSize       :: !Int
  , _rs               :: !ConsensusSpec
  , _sendMessage      :: !(ServiceRequest' -> IO ())
  , _enqueue          :: !(Event -> IO ())
  , _enqueueMultiple  :: !([Event] -> IO ())
  , _enqueueLater     :: !(Int -> Event -> IO ThreadId)
  , _killEnqueued     :: !(ThreadId -> IO ())
  , _dequeue          :: !(IO Event)
  , _clientSendMsg    :: !(OutboundGeneral -> IO ())
  , _evidenceState    :: !(IO PublishedEvidenceState)
  , _timeCache        :: !(IO UTCTime)
  , _mResetLeaderNoFollowers :: !(MVar ResetLeaderNoFollowersTimeout)
  , _informEvidenceServiceOfElection :: !(IO ())
  , _mPubConsensus    :: !(MVar PublishedConsensus)
  }
makeLenses ''ConsensusEnv

mkConsensusEnv
  :: IORef Config
  -> Int
  -> Int
  -> ConsensusSpec
  -> Dispatch
  -> MVar Event
  -> IO UTCTime
  -> MVar PublishedEvidenceState
  -> MVar ResetLeaderNoFollowersTimeout
  -> MVar PublishedConsensus
  -> ConsensusEnv
mkConsensusEnv conf' cSize qSize rSpec dispatch timerTarget' timeCache' mEs mResetLeaderNoFollowers' mPubConsensus' = ConsensusEnv
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
          unless b (putStrLn "Failed to update timer MVar")
          -- TODO: what if it's already taken?
    , _killEnqueued = killThread
    , _dequeue = _unInternalEvent <$> readComm ie'
    , _clientSendMsg = writeComm cog'
    , _evidenceState = readMVar mEs
    , _timeCache = timeCache'
    , _mResetLeaderNoFollowers = mResetLeaderNoFollowers'
    , _informEvidenceServiceOfElection = writeComm ev' ClearConvincedNodes
    , _mPubConsensus = mPubConsensus'
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

readConfig :: Consensus Config
readConfig = view cfg >>= liftIO . readIORef

viewConfig :: Getting r Config r -> Consensus r
viewConfig l = do
  (c :: Config) <- view cfg >>= liftIO . readIORef
  return $ view l c
