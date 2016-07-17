{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Juno.Types.Service.Evidence
  ( EvidenceProcEnv
  , Result(..)
  , checkEvidence
  , processResult
  , EvidenceChannel(..)
  , EvidenceEnv(..)
  , logService, evidence, mConfig, mPubStateTo, mEvCache, mResetLeaderNoFollowers
  -- TODO: re-integrate EKG when Evidence Service is finished and hspec tests are written
  --, publishMetric
  , debugFn
  , module X
  ) where

import Control.Lens hiding (Index)
import Control.Monad.Trans.Reader
import Control.Concurrent (MVar)
import Data.IORef (IORef)

import qualified Data.Sequence as Seq
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Data.Typeable

import Juno.Types.Base as X
import Juno.Types.Config as X
import Juno.Types.Message as X
import Juno.Types.Comms as X
import Juno.Types.Evidence as X
import Juno.Types.Event (ResetLeaderNoFollowersTimeout)
--import Juno.Types.Metric (Metric)
import Juno.Types.Service.Log (LogServiceChannel)

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

data EvidenceEnv = EvidenceEnv
  { _logService :: LogServiceChannel
  , _evidence :: EvidenceChannel
  , _mResetLeaderNoFollowers :: MVar ResetLeaderNoFollowersTimeout
  , _mConfig :: IORef Config
  , _mPubStateTo :: MVar EvidenceState
  , _mEvCache :: MVar EvidenceCache
  , _debugFn :: (String -> IO ())
--  , _publishMetric :: Metric -> IO ()
  }
makeLenses ''EvidenceEnv

type EvidenceProcEnv = ReaderT EvidenceEnv IO

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
    , _rLogIndex :: !LogIndex
    , _rReceivedAt :: !(Maybe ReceivedAt)}|
  FutureEvidence
  -- * Evidence is for some future log entry that we don't have access too
    { _rAER :: !AppendEntriesResponse }|
  Successful
  -- * Replication occurred and the incremental hash matches our own
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex
    , _rReceivedAt :: !(Maybe ReceivedAt)}|
  SuccessfulSteadyState
  -- * Nothing's going on besides heartbeats
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex }|
  SuccessfulButTooOld
  -- * Evidence it too old to check (not in our cache)
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex }|
  MisMatch
  -- * Sender was successful BUT incremental hash doesn't match our own
  -- NB: this is a big deal as something went seriously wrong BUT it's the sender's problem and not ours
  -- ... unless we're the odd man out
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex }
  deriving (Show, Eq)

getTimestamp :: Provenance -> Maybe ReceivedAt
getTimestamp NewMsg = Nothing
getTimestamp ReceivedMsg{..} = _pTimeStamp

-- `checkEvidence` and `processResult` are staying here to keep them close to result
checkEvidence :: EvidenceCache -> EvidenceState -> AppendEntriesResponse -> Result
checkEvidence ec es aer@(AppendEntriesResponse{..}) =
  if not _aerConvinced
    then Unconvinced _aerNodeId _aerIndex
  else if not _aerSuccess
    then Unsuccessful _aerNodeId _aerIndex (getTimestamp _aerProvenance)
  else if _aerIndex < minLogIdx ec
    then if _aerIndex == _esCommitIndex es && _aerHash == hashAtCommitIndex ec
         then SuccessfulSteadyState _aerNodeId _aerIndex
         else SuccessfulButTooOld _aerNodeId _aerIndex
  else if _aerIndex > maxLogIdx ec
    then FutureEvidence aer
  else if Seq.index (hashes ec) (fromIntegral $ _aerIndex - (minLogIdx ec)) == _aerHash
    then Successful _aerNodeId _aerIndex (getTimestamp _aerProvenance)
    else MisMatch _aerNodeId _aerIndex
    -- this one is interesting. We are going to make it the responsibility of the follower to identify that they have a bad incremental hash
    -- and prune all of their uncommitted logs.
{-# INLINE checkEvidence #-}

processResult :: Result -> EvidenceProcessor ()
processResult Unconvinced{..} = do
  esConvincedNodes %= Set.delete _rNodeId
  esNodeStates %= Map.insert _rNodeId _rLogIndex
processResult Unsuccessful{..} = do
  esConvincedNodes %= Set.insert _rNodeId
  esNodeStates %= Map.insert _rNodeId _rLogIndex
  esResetLeaderNoFollowers .= True
processResult FutureEvidence{..} = do
  esFutureEvidence %= (:) _rAER
processResult Successful{..} = do
  esConvincedNodes %= Set.insert _rNodeId
  esResetLeaderNoFollowers .= True
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
           | otherwise -> return ()
      -- this one is interesting, we have an old but successful message... I think we just drop it
processResult SuccessfulSteadyState{..} = do
  -- basically, nothings going on and these are just heartbeats
  esNodeStates %= Map.insert _rNodeId _rLogIndex
  esResetLeaderNoFollowers .= True
processResult SuccessfulButTooOld{..} = return ()
  -- this is just a wayward message. If the leader's understanding of the follower's state is incorrect, we'll get an
  -- unsuccessful
processResult MisMatch{..} = do
  esMismatchNodes %= Set.insert _rNodeId
{-# INLINE processResult #-}
