{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Juno.Types.Evidence
  ( EvidenceCache(..), initEvidenceCache
  , EvidenceState(..), initEvidenceState
  , esQuorumSize, esNodeStates, esConvincedNodes, esPartialEvidence
  , esCommitIndex, esFutureEvidence, esMismatchNodes, esResetLeaderNoFollowers
  , EvidenceProcessor
  , Evidence(..)
  , EvidenceChannel(..)
  , module X
  ) where

import Control.Lens hiding (Index)

import Control.Monad.Trans.State.Strict
import qualified Control.Concurrent.Chan.Unagi as Unagi
import Control.Concurrent (MVar)

import Data.ByteString (ByteString)
import Data.Sequence (Seq)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set

import Data.Typeable

import Juno.Types.Base as X
import Juno.Types.Config as X
import Juno.Types.Message as X
import Juno.Types.Comms as X

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
  Tick Tock
  deriving (Show, Eq, Typeable)

newtype EvidenceChannel =
  EvidenceChannel (Unagi.InChan Evidence, MVar (Maybe (Unagi.Element Evidence, IO Evidence), Unagi.OutChan Evidence))

instance Comms Evidence EvidenceChannel where
  initComms = EvidenceChannel <$> initCommsUnagi
  readComm (EvidenceChannel (_,o)) = readCommUnagi o
  readComms (EvidenceChannel (_,o)) = readCommsUnagi o
  writeComm (EvidenceChannel (i,_)) = writeCommUnagi i

data EvidenceCache = EvidenceCache
  { minLogIdx :: !LogIndex
  , maxLogIdx :: !LogIndex
  , lastLogTerm :: !Term
  , hashes :: !(Seq ByteString)
  , hashAtCommitIndex :: !ByteString
  } deriving (Show)

initEvidenceCache :: EvidenceCache
initEvidenceCache = EvidenceCache
  { minLogIdx = startIndex + 1
  , maxLogIdx = startIndex + 1
  , lastLogTerm = startTerm
  , hashes = mempty
  , hashAtCommitIndex = mempty
  }

data EvidenceState = EvidenceState
  { _esQuorumSize :: Int
  , _esNodeStates :: !(Map NodeId LogIndex)
  , _esConvincedNodes :: !(Set NodeId)
  , _esPartialEvidence :: !(Map LogIndex Int)
  , _esCommitIndex :: !LogIndex
  , _esFutureEvidence :: ![AppendEntriesResponse]
  , _esMismatchNodes :: !(Set NodeId)
  , _esResetLeaderNoFollowers :: Bool
  } deriving (Show)
makeLenses ''EvidenceState

-- | Quorum Size for evidence processing is a different size than used elsewhere, specifically 1 less.
-- The reason is that to get a match on the hash, the receiving node already needs to have replicated
-- the entry. As such, getting a match that is counted when checking evidence implies that count is already +1
-- This note is here because we used to process our own evidence, which was stupid.
getEvidenceQuorumSize :: Int -> Int
getEvidenceQuorumSize n = floor (fromIntegral n / 2 :: Float)

initEvidenceState :: Set NodeId -> LogIndex -> EvidenceState
initEvidenceState otherNodes' commidIndex' = EvidenceState
  { _esQuorumSize = getEvidenceQuorumSize $ Set.size otherNodes'
  , _esNodeStates = Map.fromSet (\_ -> commidIndex') otherNodes'
  , _esConvincedNodes = Set.empty
  , _esPartialEvidence = Map.empty
  , _esCommitIndex = commidIndex'
  , _esFutureEvidence = []
  , _esMismatchNodes = Set.empty
  , _esResetLeaderNoFollowers = False
  }

type EvidenceProcessor = State EvidenceState
