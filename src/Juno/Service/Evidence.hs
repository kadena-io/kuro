{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Service.Evidence where

import Control.Lens hiding (Index)
import Control.Monad.Trans.State.Strict

import Data.ByteString (ByteString)

import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set



import Juno.Types hiding (quorumSize)

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

initEvidenceState :: Int -> Set NodeId -> LogIndex -> EvidenceState
initEvidenceState quorumSize' otherNodes' commidIndex' = EvidenceState
  { _esQuorumSize = quorumSize'
  , _esNodeStates = Map.fromSet (\_ -> commidIndex') otherNodes'
  , _esUnconvincedNodes = otherNodes'
  , _esPartialEvidence = Map.empty
  , _esCommitIndex = commidIndex'
  , _esFutureEvidence = []
  , _esMismatchNodes = Set.empty
  }

type EvidenceProcessor = StateT EvidenceState IO

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
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex }
  deriving (Show, Eq)


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
    Nothing -> esNodeStates %= Map.insert _rNodeId _rLogIndex
    Just i | i < _rLogIndex -> do
               esNodeStates %= Map.insert _rNodeId _rLogIndex
               esPartialEvidence %= Map.insertWith (+) _rLogIndex 1
               esPartialEvidence %= Map.alter (maybe Nothing (\cnt -> if cnt - 1 <= 0
                                                               then Nothing
                                                               else Just (cnt - 1))
                                              ) _rLogIndex
           | otherwise -> return ()
processResult SuccessfulButOld{..} = do
  esUnconvincedNodes %= Set.delete _rNodeId
  esNodeStates %= Map.insert _rNodeId _rLogIndex
processResult MisMatch{..} = do
  esMismatchNodes %= Set.insert _rNodeId
{-# INLINE processResult #-}

checkForNewCommitIndex :: Int -> Map LogIndex Int -> Either Int LogIndex
checkForNewCommitIndex evidenceNeeded partialEvidence = go (Map.toDescList partialEvidence) evidenceNeeded
  where
    go [] eStillNeeded = Left eStillNeeded
    go ((li, cnt):pes) en
      | en - cnt <= 0 = Right li
      | otherwise     = go pes (en - cnt)
{-# INLINE checkForNewCommitIndex #-}

processEvidence :: [AppendEntriesResponse] -> EvidenceCache -> EvidenceProcessor (Either Int LogIndex)
processEvidence aers ec = do
  es <- get
  mapM_ processResult (checkEvidence ec es <$> aers)
  checkForNewCommitIndex (_esQuorumSize es) <$> use esPartialEvidence
