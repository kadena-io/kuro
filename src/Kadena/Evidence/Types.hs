{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.Evidence.Types
  ( PublishedEvidenceState(..)
  , pesConvincedNodes, pesNodeStates
  , Evidence(..)
  , EvidenceChannel(..)
  , Result(..)
  , CommitCheckResult(..)
  , module X
  ) where

import Control.Lens hiding (Index)
import Control.Concurrent.Chan (Chan)

import Data.Map.Strict (Map)
import Data.Set (Set)

import Data.Typeable
import Data.Thyme.Clock (UTCTime)

import Kadena.Types.Base as X
import Kadena.Types.Config as X
import Kadena.Types.Message as X
import Kadena.Types.Comms as X

import Kadena.Types.Event (Beat)

data Evidence =
  -- * A list of verified AER's, the turbine handles the crypto
  VerifiedAER { _unVerifiedAER :: [AppendEntriesResponse]} |
  -- * When we verify a new leader, become a candidate or become leader we need to clear out
  -- the set of convinced nodes. SenderService.BroadcastAE needs this info for attaching votes
  -- to the message
  ClearConvincedNodes |
  -- * The LogService has a pretty good idea of what hashes we'll need to check and can pre-cache
  -- them with us here. Log entries come in batches and AER's are only issued pertaining to the last.
  -- So, whenever LogService sees a new batch come it, it hands us the info for the last one.
  -- We will have misses -- if nodes are out of sync they may get different batches but overall this should
  -- function fine.
  CacheNewHash { _cLogIndex :: LogIndex , _cHash :: Hash } |
  Bounce | -- TODO: change how config changes are handled so we don't use bounce
  Heart Beat
  deriving (Show, Eq, Typeable)

newtype EvidenceChannel = EvidenceChannel (Chan Evidence)

instance Comms Evidence EvidenceChannel where
  initComms = EvidenceChannel <$> initCommsNormal
  readComm (EvidenceChannel c) = readCommNormal c
  writeComm (EvidenceChannel c) = writeCommNormal c

data PublishedEvidenceState = PublishedEvidenceState
  { _pesConvincedNodes :: !(Set NodeId)
  , _pesNodeStates :: !(Map NodeId (LogIndex,UTCTime))
  } deriving (Show)
makeLenses ''PublishedEvidenceState

-- | Result of the evidence check
-- NB: there are some optimizations that can be done, but I choose not to because they complicate matters and I think
-- this system will be used to optimize messaging in the future (e.g. don't send AER's to nodes who agree with you).
-- For that, we'll need to check crypto anyway
data Result =
  Unconvinced
  -- * Sender does not believe in leader.
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex
    , _rReceivedAt :: !UTCTime }|
  Unsuccessful
  -- * Sender believes in leader but failed to replicate. This usually this occurs when a follower is catching up
  -- * and an AE was sent with a PrevLogIndex > LastLogIndex
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex
    , _rReceivedAt :: !UTCTime }|
  Successful
  -- * Replication occurred and the incremental hash matches our own
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex
    , _rReceivedAt :: !UTCTime }|
  SuccessfulSteadyState
  -- * Nothing's going on besides heartbeats
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex
    , _rReceivedAt :: !UTCTime }|
  SuccessfulButCacheMiss
  -- * Our pre-cached evidence was lacking this particular hash, so we need to request it
    { _rAer :: AppendEntriesResponse }|
  MisMatch
  -- * Sender was successful BUT incremental hash doesn't match our own
  -- NB: this is a big deal as something went seriously wrong BUT it's the sender's problem and not ours
  -- ... unless we're the odd man out
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex } |
  Noop
  -- * This is for a very specific AER event, IFF:
  --   - we have already counted evidence for another AER for this node that is for a later LogIndex
  --   - this Noop AER was received within less than one MaxElectionTimeBound
  -- Why: because AER's can and do come in out of order sometimes. We don't want to decrease a the nodeState
  --      for a given node if we can avoid it.
  deriving (Show, Eq)

data CommitCheckResult =
  SteadyState {_ccrCommitIndex :: !LogIndex}|
  NeedMoreEvidence {_ccrEvRequired :: Int} |
  StrangeResultInProcessor {_ccrCommitIndex :: !LogIndex} |
  NewCommitIndex {_ccrCommitIndex :: !LogIndex}
  deriving (Show)
