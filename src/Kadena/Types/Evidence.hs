{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.Types.Evidence
  ( EvidenceState(..), initEvidenceState
  , esQuorumSize, esNodeStates, esConvincedNodes, esPartialEvidence
  , esCommitIndex, esCacheMissAers, esMismatchNodes, esResetLeaderNoFollowers
  , esHashAtCommitIndex, esEvidenceCache, esMaxCachedIndex, esMaxElectionTimeout
  , PublishedEvidenceState(..)
  , pesConvincedNodes, pesNodeStates
  , EvidenceProcessor
  , Evidence(..)
  , EvidenceChannel(..)
  , module X
  ) where

import Control.Lens hiding (Index)

import Control.Monad.Trans.State.Strict
import Control.Concurrent.Chan (Chan)

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set

import Data.Typeable
import Data.Thyme.Clock (UTCTime)

import Kadena.Types.Base as X
import Kadena.Types.Config as X
import Kadena.Types.Message as X
import Kadena.Types.Comms as X

data Evidence =
  -- * A list of verified AER's, the turbine handles the crypto
  VerifiedAER { _unVerifiedAER :: [AppendEntriesResponse]} |
  -- * When we verify a new leader, become a candidate or become leader we need to clear out
  -- the set of convinced nodes. SenderService.BroadcastAE needs this info for attaching votes
  -- to the message
  ClearConvincedNodes |
  -- * A bit of future tech/trying out a design. When we have participant changes, we can sync
  -- Evidence thread with this.
  Bounce |
  -- * The LogService has a pretty good idea of what hashes we'll need to check and can pre-cache
  -- them with us here. Log entries come in batches and AER's are only issued pertaining to the last.
  -- So, whenever LogService sees a new batch come it, it hands us the info for the last one.
  -- We will have misses -- if nodes are out of sync they may get different batches but overall this should
  -- function fine.
  CacheNewHash { _cLogIndex :: LogIndex , _cHash :: ByteString } |
  Tick Tock
  deriving (Show, Eq, Typeable)

newtype EvidenceChannel = EvidenceChannel (Chan Evidence)

instance Comms Evidence EvidenceChannel where
  initComms = EvidenceChannel <$> initCommsNormal
  readComm (EvidenceChannel c) = readCommNormal c
  writeComm (EvidenceChannel c) = writeCommNormal c

data EvidenceState = EvidenceState
  { _esQuorumSize :: !Int
  , _esNodeStates :: !(Map NodeId (LogIndex, UTCTime))
  , _esConvincedNodes :: !(Set NodeId)
  , _esPartialEvidence :: !(Map LogIndex Int)
  , _esCommitIndex :: !LogIndex
  , _esMaxCachedIndex :: !LogIndex
  , _esCacheMissAers :: !(Set AppendEntriesResponse)
  , _esMismatchNodes :: !(Set NodeId)
  , _esResetLeaderNoFollowers :: Bool
  , _esHashAtCommitIndex :: !ByteString
  , _esEvidenceCache :: !(Map LogIndex ByteString)
  , _esMaxElectionTimeout :: !Int
  } deriving (Show, Eq)
makeLenses ''EvidenceState

data PublishedEvidenceState = PublishedEvidenceState
  { _pesConvincedNodes :: !(Set NodeId)
  , _pesNodeStates :: !(Map NodeId (LogIndex,UTCTime))
  } deriving (Show)
makeLenses ''PublishedEvidenceState

-- | Quorum Size for evidence processing is a different size than used elsewhere, specifically 1 less.
-- The reason is that to get a match on the hash, the receiving node already needs to have replicated
-- the entry. As such, getting a match that is counted when checking evidence implies that count is already +1
-- This note is here because we used to process our own evidence, which was stupid.
getEvidenceQuorumSize :: Int -> Int
getEvidenceQuorumSize n = 1 + floor (fromIntegral n / 2 :: Float)

initEvidenceState :: Set NodeId -> LogIndex -> Int -> EvidenceState
initEvidenceState otherNodes' commidIndex' maxElectionTimeout' = EvidenceState
  { _esQuorumSize = getEvidenceQuorumSize $ Set.size otherNodes'
  , _esNodeStates = Map.fromSet (\_ -> (commidIndex',minBound)) otherNodes'
  , _esConvincedNodes = Set.empty
  , _esPartialEvidence = Map.empty
  , _esCommitIndex = commidIndex'
  , _esMaxCachedIndex = commidIndex'
  , _esCacheMissAers = Set.empty
  , _esMismatchNodes = Set.empty
  , _esResetLeaderNoFollowers = False
  , _esHashAtCommitIndex = mempty
  , _esEvidenceCache = Map.singleton startIndex mempty
  , _esMaxElectionTimeout = maxElectionTimeout'
  }

type EvidenceProcessor = State EvidenceState
