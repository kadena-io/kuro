{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Config.ClusterMembership
  ( checkQuorum
  , checkQuorumIncluding
  , ClusterMembership
  , containsAllNodesExcluding
  , countOthers
  , countTransitional
  , hasTransitionalNodes
  , minQuorumOthers
  , minQuorumTransitional
  , mkClusterMembership
  , othersExcluding
  , othersIncluding
  , otherNodes
  , othersAsText
  , setTransitional
  , transitionalExcluding
  , transitionalIncluding
  , transitionalNodes
  ) where

import Data.Aeson
import Data.Set (Set)
import qualified Data.Set as Set
import Data.String.Conv
import Data.Text (Text)
import qualified Data.Text as T
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

-- | Create a ClusterMembership from the given set of "other" nodes (all nodes in the cluster minus
-- the node currently runnning) and the given config-change "transitional" nodes.
mkClusterMembership :: Set NodeId -> Set NodeId -> ClusterMembership
mkClusterMembership others transitional =
  ClusterMembership
    { _cmOtherNodes = others
    , _cmChangeToNodes = transitional }

-- | Does this ClusterMembership have any 'transitional' nodes?
hasTransitionalNodes :: ClusterMembership -> Bool
hasTransitionalNodes cm =
  _cmChangeToNodes cm /= Set.empty

-- | Update the ClusterMembership with the supplied list of config-change "transitional" nodes
setTransitional :: ClusterMembership -> Set NodeId -> ClusterMembership
setTransitional cm transNodes =
  mkClusterMembership (_cmOtherNodes cm) transNodes

-- | Count the number of "other" nodes 
-- (all nodes in the cluster minus the node currently runnning)
countOthers :: ClusterMembership -> Int
countOthers cm = Set.size $ _cmOtherNodes cm

-- | Count the number of config-change "transitional" nodes
countTransitional :: ClusterMembership -> Int
countTransitional cm = Set.size $ _cmChangeToNodes cm

-- | Get the quorum count required, considering only the set of "other" nodes
-- (all nodes in the cluster minus the node currently runnning)
minQuorumOthers :: ClusterMembership -> Int
minQuorumOthers cm =
  (calcMinQuorum $ (Set.size $ otherNodes cm) + 1)

-- | Get the quorum count required, considering the config-change "transitional" nodes only
minQuorumTransitional :: ClusterMembership -> Int
minQuorumTransitional cm =
  calcMinQuorum $ Set.size $ transitionalNodes cm

-- | Get the set of "other" nodes -- all nodes in the cluster minus the node currently runnning
otherNodes :: ClusterMembership -> Set NodeId
otherNodes = _cmOtherNodes

-- | Sames as the otherNodes function, but excluding the specified NodeId
othersExcluding :: ClusterMembership -> NodeId -> Set NodeId
othersExcluding cm nodeToExclude =
  nodeToExclude `Set.delete` (otherNodes cm)

-- | Sames as the otherNodes function, but including the specified NodeId
othersIncluding :: ClusterMembership -> NodeId -> Set NodeId
othersIncluding cm nodeToInclude =
  nodeToInclude `Set.insert` (otherNodes cm)

-- | Get the names of the "other" nodes as Text with commas separating the names 
othersAsText :: ClusterMembership -> Text
othersAsText cm =
  let others = Set.toList $ otherNodes cm
      txtIds = fmap (toS . unAlias . _alias) others :: [Text]
  in T.intercalate ", " txtIds

-- | Get the set of config-change "transitional" cluster members
transitionalNodes :: ClusterMembership -> Set NodeId
transitionalNodes = _cmChangeToNodes

-- | Get the set of config-change "transitional" cluster members, after deleting the given nodeId
-- from the set
transitionalExcluding :: ClusterMembership -> NodeId -> Set NodeId
transitionalExcluding cm nodeToExclude =
  nodeToExclude `Set.delete` (transitionalNodes cm)

-- | Get the set of config-change "transitional" cluster members, adding the given nodeId to the set
transitionalIncluding :: ClusterMembership -> NodeId -> Set NodeId
transitionalIncluding cm nodeToInclude =
  nodeToInclude `Set.insert` (transitionalNodes cm)

-- | Check if the set of 'votes' in the second parameter constitutes a quorum with respect to the
-- ClusterMembership
checkQuorum :: ClusterMembership -> Set NodeId -> Bool
checkQuorum cm voteIds =
  checkSetQuorum (otherNodes cm) voteIds && checkSetQuorum (transitionalNodes cm) voteIds

-- | Check if the set of 'votes' in the second parameter constitutes a quorum with respect to the
-- set of all cluster nodes in the first parameter
checkSetQuorum :: Set NodeId -> Set NodeId -> Bool
checkSetQuorum nodes voteIds =
  let votes = Set.filter ((flip Set.member) nodes) voteIds
      numVotes = Set.size votes
      quorum = calcMinQuorum $ Set.size nodes
  in numVotes >= quorum

-- | Check if the given set of NodeIds constitutes a quorum. Include the specified NodeId when calculating the
-- size of the cluster.
checkQuorumIncluding :: ClusterMembership -> Set NodeId -> NodeId -> Bool
checkQuorumIncluding cm votes nodeToInclude =
  let othersInc = othersIncluding cm nodeToInclude
      othersQuorum = calcMinQuorum $ Set.size othersInc
      othersVotes = Set.size $ Set.filter (\x -> x `elem` othersInc) votes
      trans = transitionalNodes cm
      transQuorum = calcMinQuorum $ Set.size trans
      transVotes = Set.size $ Set.filter (\x -> x `elem` trans) votes
  in othersVotes >= othersQuorum && transVotes >= transQuorum

-- | Calculate the quorum from the given cluster size.  For now this is a simple majority, but it needs to be
-- changed to reflect the formula in the Tangaroa paper
calcMinQuorum :: Int -> Int
calcMinQuorum 0 = 0
calcMinQuorum n = 1 + floor (fromIntegral n / 2 :: Float)

-- | Does the set passed in the second parameter contains all nodes in the cluster, with the
-- exclusion of the particular NodeId passed in the third paramater?
containsAllNodesExcluding :: ClusterMembership -> Set NodeId -> NodeId -> Bool
containsAllNodesExcluding cm nodesToCheck nodeToExclude =
  let othersEx = othersExcluding cm nodeToExclude
      transEx = transitionalExcluding cm nodeToExclude
  in (othersEx == Set.filter (\n -> n `elem` othersEx) nodesToCheck)
       && (transEx == Set.filter(\n -> n `elem` transEx) nodesToCheck)

