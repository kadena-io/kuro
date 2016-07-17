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
  , logService, evidence, mConfig, mPubStateTo, mResetLeaderNoFollowers
  -- TODO: re-integrate EKG when Evidence Service is finished and hspec tests are written
  --, publishMetric
  , debugFn
  , CommitCheckResult(..)
  , module X
  ) where

import Control.Lens hiding (Index)
import Control.Monad.Trans.Reader
import Control.Concurrent (MVar)
import Data.IORef (IORef)

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Juno.Types.Base as X
import Juno.Types.Config as X
import Juno.Types.Message as X
import Juno.Types.Comms as X
import Juno.Types.Evidence as X
import Juno.Types.Event (ResetLeaderNoFollowersTimeout)
--import Juno.Types.Metric (Metric)
import Juno.Types.Service.Log (LogServiceChannel)

data EvidenceEnv = EvidenceEnv
  { _logService :: LogServiceChannel
  , _evidence :: EvidenceChannel
  , _mResetLeaderNoFollowers :: MVar ResetLeaderNoFollowersTimeout
  , _mConfig :: IORef Config
  , _mPubStateTo :: MVar PublishedEvidenceState
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
  Successful
  -- * Replication occurred and the incremental hash matches our own
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex
    , _rReceivedAt :: !(Maybe ReceivedAt)}|
  SuccessfulSteadyState
  -- * Nothing's going on besides heartbeats
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex }|
  SuccessfulButCacheMiss
  -- * Our pre-cached evidence was lacking this particular hash, so we need to request it
    { _rAer :: AppendEntriesResponse }|
  MisMatch
  -- * Sender was successful BUT incremental hash doesn't match our own
  -- NB: this is a big deal as something went seriously wrong BUT it's the sender's problem and not ours
  -- ... unless we're the odd man out
    { _rNodeId :: !NodeId
    , _rLogIndex :: !LogIndex }
  deriving (Show, Eq)

data CommitCheckResult =
  SteadyState {_ccrCommitIndex :: !LogIndex}|
  NeedMoreEvidence {_ccrEvRequired :: Int} |
  NewCommitIndex {_ccrCommitIndex :: !LogIndex}
  deriving (Show)

getTimestamp :: Provenance -> Maybe ReceivedAt
getTimestamp NewMsg = Nothing
getTimestamp ReceivedMsg{..} = _pTimeStamp

-- `checkEvidence` and `processResult` are staying here to keep them close to result
checkEvidence :: EvidenceState -> AppendEntriesResponse -> Result
checkEvidence es aer@(AppendEntriesResponse{..}) =
  if not _aerConvinced
    then Unconvinced _aerNodeId _aerIndex
  else if not _aerSuccess
    then Unsuccessful _aerNodeId _aerIndex (getTimestamp _aerProvenance)
  else if _aerIndex == _esCommitIndex es && _aerHash == es ^. esHashAtCommitIndex
    then SuccessfulSteadyState _aerNodeId _aerIndex
  else case Map.lookup _aerIndex (es ^. esEvidenceCache) of
    Nothing -> SuccessfulButCacheMiss aer
    Just h | h == _aerHash -> Successful _aerNodeId _aerIndex (getTimestamp _aerProvenance)
           | otherwise     -> MisMatch _aerNodeId _aerIndex
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
processResult Successful{..} = do
  esConvincedNodes %= Set.insert _rNodeId
  esMismatchNodes %= Set.delete _rNodeId
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
  esMismatchNodes %= Set.delete _rNodeId
  esResetLeaderNoFollowers .= True
processResult SuccessfulButCacheMiss{..} = do
  esCacheMissAers %= Set.insert _rAer
processResult MisMatch{..} = do
  esMismatchNodes %= Set.insert _rNodeId
{-# INLINE processResult #-}
