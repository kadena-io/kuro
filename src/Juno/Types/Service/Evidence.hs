{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Juno.Types.Service.Evidence
  ( EvidenceCache(..)
  , EvidenceState(..), esQuorumSize, esNodeStates, esUnconvincedNodes
  , esPartialEvidence, esCommitIndex, esFutureEvidence, esMismatchNodes
  , initEvidenceState
  , EvidenceProcessor
  , EvidenceProcEnv
  , Result(..)
  , checkEvidence
  , processResult
  , Evidence(..)
  , EvidenceChannel(..)
  , EvidenceEnv(..), logService, evidence, mConfig, mPubStateTo, mEvCache
  , debugFn
  , module X
  ) where

import Control.Lens hiding (Index)
import Control.Monad.Trans.Reader
import Control.Monad.Trans.State.Strict
import qualified Control.Concurrent.Chan.Unagi as Unagi
import Control.Concurrent (MVar)

import Data.ByteString (ByteString)

import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set

import Data.Typeable

import Juno.Types.Base as X
import Juno.Types.Config as X
import Juno.Types.Message as X
import Juno.Types.Comms as X
import Juno.Types.Service.Log (LogServiceChannel)

data Evidence =
  VerifiedAER { _unVerifiedAER :: [AppendEntriesResponse]} |
  Tick Tock |
  Bounce
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
  } deriving (Show)

data EvidenceState = EvidenceState
  { _esQuorumSize :: Int
  , _esNodeStates :: !(Map NodeId LogIndex)
  , _esUnconvincedNodes :: !(Set NodeId)
  , _esPartialEvidence :: !(Map LogIndex Int)
  , _esCommitIndex :: !LogIndex
  , _esFutureEvidence :: ![AppendEntriesResponse]
  , _esMismatchNodes :: !(Set NodeId)
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
  , _esUnconvincedNodes = otherNodes'
  , _esPartialEvidence = Map.empty
  , _esCommitIndex = commidIndex'
  , _esFutureEvidence = []
  , _esMismatchNodes = Set.empty
  }

data EvidenceEnv = EvidenceEnv
  { _logService :: LogServiceChannel
  , _evidence :: EvidenceChannel
  , _mConfig :: MVar Config
  , _mPubStateTo :: MVar EvidenceState
  , _mEvCache :: MVar EvidenceCache
  , _debugFn :: (String -> IO ())
  }
makeLenses ''EvidenceEnv

type EvidenceProcEnv = ReaderT EvidenceEnv IO
type EvidenceProcessor = State EvidenceState

-- | Result of the evidence check
-- NB: there are some optimizations that can be done, but I choose not to because they complicate matters and I think
-- this system will be used to optimize messaging in the future (e.g. don't send AER's to nodes who agree with you).
-- For that, we'll need to check crypto anyway
data Result =
  Unconvinced
  -- * Sender does not believe in leader.
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex }|
  Unsuccessful
  -- * Sender believes in leader but failed to replicate. This usually this occurs when a follower is catching up
  -- * and an AE was sent with a PrevLogIndex > LastLogIndex
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex }|
  FutureEvidence
  -- * Evidence is for some future log entry that we don't have access too
    { _rAER :: !AppendEntriesResponse }|
  Successful
  -- * Replication occurred and the incremental hash matches our own
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex }|
  SuccessfulButOld
  -- * Replication occurred and the incremental hash matches our own
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex }|
  MisMatch
  -- * Sender was successful BUT incremental hash doesn't match our own
  -- NB: this is a big deal as something went seriously wrong BUT it's the sender's problem and not ours
  -- ... unless we're the odd man out
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex }
  deriving (Show, Eq)

-- `checkEvidence` and `processResult` are staying here to keep them close to result
checkEvidence :: EvidenceCache -> EvidenceState -> AppendEntriesResponse -> Result
checkEvidence ec es aer@(AppendEntriesResponse{..}) =
  if not _aerConvinced
    then Unconvinced _aerNodeId _aerIndex
  else if not _aerSuccess
    then Unsuccessful _aerNodeId _aerIndex
  else if _aerIndex < _esCommitIndex es
    -- this one is interesting. We are going to make it the responsibility of the follower to identify that they have a bad incremental hash
    -- and prune all of their uncommitted logs.
    then SuccessfulButOld _aerNodeId _aerIndex
  else if _aerIndex > maxLogIdx ec
    then FutureEvidence aer
  else if Seq.index (hashes ec) (fromIntegral $ _aerIndex - (minLogIdx ec)) == _aerHash
    then Successful _aerNodeId _aerIndex
    else MisMatch _aerNodeId _aerIndex
{-# INLINE checkEvidence #-}

processResult :: Result -> EvidenceProcessor ()
processResult Unconvinced{..} = do
  esUnconvincedNodes %= Set.insert _rNodeId
  esNodeStates %= Map.insert _rNodeId _rLogIndex
processResult Unsuccessful{..} = do
  esUnconvincedNodes %= Set.delete _rNodeId
  esNodeStates %= Map.insert _rNodeId _rLogIndex
processResult FutureEvidence{..} = do
  esFutureEvidence %= (:) _rAER
processResult Successful{..} = do
  esUnconvincedNodes %= Set.delete _rNodeId
  lastIdx <- Map.lookup _rNodeId <$> use esNodeStates
  -- this bit is important, we don't want to double count any node's evidence so we need to decrement the old evidence (if any)
  -- and increment the new
  case lastIdx of
    Nothing -> do
      esNodeStates %= Map.insert _rNodeId _rLogIndex
      -- Adding it here is fine because esNodeState's values only are nothing if we've never heard from
      -- that node OR we've reset this service (aka membership event) and the esPartialEvidence will also
      -- be reset
      esPartialEvidence %= Map.insertWith (+) _rLogIndex 1
    Just i | i < _rLogIndex -> do
      esNodeStates %= Map.insert _rNodeId _rLogIndex
      -- Add the updated evidence
      esPartialEvidence %= Map.insertWith (+) _rLogIndex 1
      -- Remove the previous evidence, removing the key if count == 0
      esPartialEvidence %= Map.alter (maybe Nothing (\cnt -> if cnt - 1 <= 0
                                                      then Nothing
                                                      else Just (cnt - 1))
                                    ) i
           | otherwise ->
      -- this one is interesting, we have an old but successful message... I think we just drop it
      return ()
processResult SuccessfulButOld{..} = do
  esUnconvincedNodes %= Set.delete _rNodeId
  esNodeStates %= Map.insert _rNodeId _rLogIndex
processResult MisMatch{..} = do
  esMismatchNodes %= Set.insert _rNodeId
{-# INLINE processResult #-}
