{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}

module Kadena.Evidence.Spec
  ( EvidenceService
  , checkEvidence
  , processResult
  , EvidenceChannel(..)
  , EvidenceEnv(..)
  , logService, evidence, mConfig, mPubStateTo, mResetLeaderNoFollowers
  , EvidenceState(..), initEvidenceState
  , esQuorumSize, esChangeToQuorumSize, esNodeStates, esConvincedNodes, esPartialEvidence
  , esCommitIndex, esCacheMissAers, esMismatchNodes, esResetLeaderNoFollowers
  , esHashAtCommitIndex, esEvidenceCache, esMaxCachedIndex, esMaxElectionTimeout
  , esClusterMembers
  , EvidenceProcessor
  , debugFn
  , publishMetric
  , getEvidenceQuorumSize
  ) where

import Control.Lens hiding (Index)
import Control.Monad.RWS.Lazy
import Control.Monad.Trans.State.Strict
import Control.Concurrent (MVar)

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Thyme.Clock

import Kadena.Types.Base
import Kadena.Types.Metric
import Kadena.Types.Config
import Kadena.Types.Message
import Kadena.Evidence.Types
import Kadena.Types.Event (ResetLeaderNoFollowersTimeout)
import Kadena.Log.Types (LogServiceChannel)

data EvidenceEnv = EvidenceEnv
  { _logService :: !LogServiceChannel
  , _evidence :: !EvidenceChannel
  , _mResetLeaderNoFollowers :: !(MVar ResetLeaderNoFollowersTimeout)
  , _mConfig :: !(GlobalConfigTMVar)
  , _mPubStateTo :: !(MVar PublishedEvidenceState)
  , _debugFn :: !(String -> IO ())
  , _publishMetric :: !(Metric -> IO ())
  }
makeLenses ''EvidenceEnv

type EvidenceService s = RWST EvidenceEnv () s IO

data EvidenceState = EvidenceState
  { _esClusterMembers :: ! ClusterMembership
  , _esQuorumSize :: !Int
  , _esChangeToQuorumSize :: !Int
  , _esNodeStates :: !(Map NodeId (LogIndex, UTCTime))
  , _esConvincedNodes :: !(Set NodeId)
  , _esPartialEvidence :: !(Map LogIndex (Set NodeId))
  , _esCommitIndex :: !LogIndex
  , _esMaxCachedIndex :: !LogIndex
  , _esCacheMissAers :: !(Set AppendEntriesResponse)
  , _esMismatchNodes :: !(Set NodeId)
  , _esResetLeaderNoFollowers :: Bool
  , _esHashAtCommitIndex :: !Hash
  , _esEvidenceCache :: !(Map LogIndex Hash)
  , _esMaxElectionTimeout :: !Int
  } deriving (Show, Eq)
makeLenses ''EvidenceState

-- | Quorum Size for evidence processing is a different size than used elsewhere, specifically 1 less.
-- The reason is that to get a match on the hash, the receiving node already needs to have replicated
-- the entry. As such, getting a match that is counted when checking evidence implies that count is already +1
-- This note is here because we used to process our own evidence, which was stupid.
getEvidenceQuorumSize :: Int -> Int
getEvidenceQuorumSize 0 = 0
getEvidenceQuorumSize n = 1 + floor (fromIntegral n / 2 :: Float)

initEvidenceState :: ClusterMembership -> LogIndex -> Int -> EvidenceState
initEvidenceState clusterMembers' commidIndex' maxElectionTimeout' = EvidenceState
  { _esClusterMembers = clusterMembers'
  , _esQuorumSize = getEvidenceQuorumSize $ Set.size $ _cmOtherNodes clusterMembers'
  , _esChangeToQuorumSize = getEvidenceQuorumSize $ Set.size $ _cmChangeToNodes clusterMembers'
  , _esNodeStates = Map.fromSet (\_ -> (commidIndex',minBound)) (_cmOtherNodes clusterMembers')
  , _esConvincedNodes = Set.empty
  , _esPartialEvidence = Map.empty
  , _esCommitIndex = commidIndex'
  , _esMaxCachedIndex = commidIndex'
  , _esCacheMissAers = Set.empty
  , _esMismatchNodes = Set.empty
  , _esResetLeaderNoFollowers = False
  , _esHashAtCommitIndex = initialHash
  , _esEvidenceCache = Map.singleton startIndex initialHash
  , _esMaxElectionTimeout = maxElectionTimeout'
  }

type EvidenceProcessor = State EvidenceState

getTimestamp :: Provenance -> UTCTime
getTimestamp NewMsg = error "Deep invariant failure: a NewMsg AER, which doesn't have a timestamp, was received by EvidenceService"
getTimestamp ReceivedMsg{..} = case _pTimeStamp of
  Nothing -> error "Deep invariant failure: a ReceivedMsg AER encountered that doesn't have a timestamp by EvidenceService"
  Just v -> _unReceivedAt v

-- `checkEvidence` and `processResult` are staying here to keep them close to `Result`
checkEvidence :: EvidenceState -> AppendEntriesResponse -> Result
checkEvidence es aer@(AppendEntriesResponse{..}) = case Map.lookup _aerNodeId $ _esNodeStates es of
  Just (lastLogIndex', lastTimestamp')
    | fromIntegral (interval lastTimestamp' (getTimestamp _aerProvenance)) < (_esMaxElectionTimeout es)
      && _aerIndex < lastLogIndex' -> Noop
  _ -> do
    if not _aerConvinced
      then Unconvinced _aerNodeId _aerIndex (getTimestamp _aerProvenance)
    else if not _aerSuccess
      then Unsuccessful _aerNodeId _aerIndex (getTimestamp _aerProvenance)
    else if _aerIndex == _esCommitIndex es && _aerHash == es ^. esHashAtCommitIndex
      then SuccessfulSteadyState _aerNodeId _aerIndex (getTimestamp _aerProvenance)
    else case Map.lookup _aerIndex (es ^. esEvidenceCache) of
      Nothing -> SuccessfulButCacheMiss aer
      Just h | h == _aerHash -> Successful _aerNodeId _aerIndex (getTimestamp _aerProvenance)
             | otherwise     -> MisMatch _aerNodeId _aerIndex
      -- this one is interesting. We are going to make it the responsibility of the follower to identify that they have a bad incremental hash
      -- and prune all of their uncommitted logs.
{-# INLINE checkEvidence #-}


processResult :: MonadState EvidenceState m => Result -> m ()
processResult Unconvinced{..} = do
  esConvincedNodes %= Set.delete _rNodeId
  esNodeStates %= Map.insert _rNodeId (_rLogIndex, _rReceivedAt)
processResult Unsuccessful{..} = do
  esConvincedNodes %= Set.insert _rNodeId
  esNodeStates %= Map.insert _rNodeId (_rLogIndex, _rReceivedAt)
  esResetLeaderNoFollowers .= True
processResult Successful{..} = do
  esConvincedNodes %= Set.insert _rNodeId
  esMismatchNodes %= Set.delete _rNodeId
  esResetLeaderNoFollowers .= True
  lastIdx <- Map.lookup _rNodeId <$> use esNodeStates
  -- this bit is important, we don't want to double count any node's evidence so we need to
  -- decrement the old evidence (if any) and increment the new
  -- Add the updated evidence
  esPartialEvidence %= Map.insertWith Set.union _rLogIndex (Set.singleton _rNodeId)
  esNodeStates %= Map.insert _rNodeId (_rLogIndex, _rReceivedAt)
  case lastIdx of
    Just (i,_) | i < _rLogIndex ->
      -- Remove the previous evidence (i.e. removing the nodeId from the Set corresponding to lastIdx,
      -- and removing the key if the resulting Set is empty)
      esPartialEvidence %= Map.alter (maybe Nothing f) i where
        f :: Set NodeId -> Maybe (Set NodeId)
        f s = let deleted = Set.delete _rNodeId s
              in if null s then Nothing else Just deleted
    Just _ -> return ()
    Nothing -> return ()

-- this one is interesting, we have an old but successful message... I think we just drop it
processResult SuccessfulSteadyState{..} = do
  -- basically, nothings going on and these are just heartbeats
  esConvincedNodes %= Set.insert _rNodeId
  esNodeStates %= Map.insert _rNodeId (_rLogIndex, _rReceivedAt)
  esMismatchNodes %= Set.delete _rNodeId
  esResetLeaderNoFollowers .= True
processResult SuccessfulButCacheMiss{..} = do
  esConvincedNodes %= Set.insert (_aerNodeId _rAer)
  esCacheMissAers %= Set.insert _rAer
processResult MisMatch{..} = do
  esConvincedNodes %= Set.insert _rNodeId
  esMismatchNodes %= Set.insert _rNodeId
processResult Noop = return ()
{-# INLINE processResult #-}
