{-# LANGUAGE DeriveGeneric #-}

module Kadena.Config.ClusterMembership
  ( checkQuorum
  , checkVoteQuorum
  , ClusterMembership
  , countOthers
  , countTransitional
  , getCurrentNodes
  , getQuorumSize
  , getQuorumSizeOthers
  , hasTransitionalNodes
  , mkClusterMembership
  , otherNodes
  , setTransitional
  , transitionalNodes
  ) where

import Data.Aeson
import Data.Set (Set)
import qualified Data.Set as Set
import GHC.Generics

import Kadena.Types.Base
import Pact.Types.Util

data ClusterMembership = ClusterMembership
  { _cmOtherNodes :: !(Set NodeId)
  , _cmChangeToNodes :: !(Set NodeId)
  } deriving (Show, Eq, Generic)
instance ToJSON ClusterMembership where
  toJSON = lensyToJSON 3
instance FromJSON ClusterMembership where
  parseJSON = lensyParseJSON 3

mkClusterMembership :: Set NodeId -> Set NodeId -> ClusterMembership
mkClusterMembership others transitional =
  ClusterMembership
    { _cmOtherNodes = others
    , _cmChangeToNodes = transitional }

hasTransitionalNodes :: ClusterMembership -> Bool
hasTransitionalNodes cm =
  _cmChangeToNodes cm /= Set.empty

setTransitional :: ClusterMembership -> Set NodeId -> ClusterMembership
setTransitional cm transNodes = mkClusterMembership (_cmOtherNodes cm) transNodes

countOthers :: ClusterMembership -> Int
countOthers cm = Set.size $ _cmOtherNodes cm

countTransitional :: ClusterMembership -> Int
countTransitional cm = Set.size $ _cmChangeToNodes cm

otherNodes :: ClusterMembership -> Set NodeId
otherNodes = _cmOtherNodes

transitionalNodes :: ClusterMembership -> Set NodeId
transitionalNodes = _cmChangeToNodes

checkQuorum :: Set NodeId -> Set NodeId -> Bool
checkQuorum voteIds nodes =
  let votes = Set.filter ((flip Set.member) nodes) voteIds
      numVotes = Set.size votes
      quorum = getQuorumSize numVotes
  in numVotes >= quorum

checkVoteQuorum :: ClusterMembership -> Set NodeId -> NodeId -> IO Bool
checkVoteQuorum clusterMembers votes myId = do
  let currentNodes = getCurrentNodes clusterMembers myId
  let currentQuorum = getQuorumSize $ Set.size currentNodes
  let currentVotes = Set.size $ Set.filter (\x -> x `elem` currentNodes) votes
  let newNodes = _cmChangeToNodes clusterMembers
  let changeToQuorum = getQuorumSizeOthers newNodes myId
  let changeToVotes = Set.size $ Set.filter (\x -> x `elem` newNodes) votes
  return $ currentVotes >= currentQuorum && changeToVotes >= changeToQuorum

getCurrentNodes :: ClusterMembership -> NodeId -> Set NodeId
getCurrentNodes clusterMembers  myId =
  let others = _cmOtherNodes clusterMembers
  in myId `Set.insert` others

getQuorumSize :: Int -> Int
getQuorumSize 0 = 0
getQuorumSize n = 1 + floor (fromIntegral n / 2 :: Float)

-- | Similar to getQuorumSize, but before determining the number of Ids, remove the given id (if it
--   is present) from the set of all ids
getQuorumSizeOthers :: Set NodeId -> NodeId -> Int
getQuorumSizeOthers ids myId =
    let others = Set.delete myId ids
    in getQuorumSize (Set.size others)
