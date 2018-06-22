{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Config.ClusterMembership
  ( calcMinQuorum
  , checkQuorum
  , checkQuorumIncluding
  , ClusterMembership
  , countOthers
  , countTransitional
  , hasTransitionalNodes
  , minQuorumOthers
  , minQuorumTransitional
  , mkClusterMembership
  , otherIncluding
  , otherNodes
  , othersAsText
  , setTransitional
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

minQuorumOthers :: ClusterMembership -> Int
minQuorumOthers cm = calcMinQuorum $ Set.size $ otherNodes cm

minQuorumTransitional :: ClusterMembership -> Int
minQuorumTransitional cm = calcMinQuorum $ Set.size $ transitionalNodes cm

otherNodes :: ClusterMembership -> Set NodeId
otherNodes = _cmOtherNodes

otherIncluding :: ClusterMembership -> NodeId -> Set NodeId
otherIncluding cm nodeToInclude =
  nodeToInclude `Set.insert` (otherNodes cm)

othersAsText :: ClusterMembership -> Text
othersAsText cm =
  let others = Set.toList $ otherNodes cm
      txtIds = fmap (toS . unAlias . _alias) others :: [Text]
  in T.intercalate ", " txtIds

transitionalNodes :: ClusterMembership -> Set NodeId
transitionalNodes = _cmChangeToNodes

transitionalIncluding :: ClusterMembership -> NodeId -> Set NodeId
transitionalIncluding cm nodeToInclude =
  nodeToInclude `Set.insert` (transitionalNodes cm)

checkQuorum :: ClusterMembership -> Set NodeId -> Bool
checkQuorum cm voteIds =
  checkSetQuorum (otherNodes cm) voteIds && checkSetQuorum (transitionalNodes cm) voteIds

checkSetQuorum :: Set NodeId -> Set NodeId -> Bool
checkSetQuorum nodes voteIds =
  let votes = Set.filter ((flip Set.member) nodes) voteIds
      numVotes = Set.size votes
      quorum = calcMinQuorum $ Set.size nodes
  in numVotes >= quorum

checkQuorumIncluding :: ClusterMembership -> Set NodeId -> NodeId -> Bool
checkQuorumIncluding cm votes nodeToInclude =
  let othersInc = otherIncluding cm nodeToInclude
      othersQuorum = calcMinQuorum $ Set.size othersInc
      othersVotes = Set.size $ Set.filter (\x -> x `elem` othersInc) votes
      transInc = transitionalIncluding cm nodeToInclude
      transQuorum = calcMinQuorum $ Set.size transInc
      transVotes = Set.size $ Set.filter (\x -> x `elem` transInc) votes
  in othersVotes >= othersQuorum && transVotes >= transQuorum

calcMinQuorum :: Int -> Int
calcMinQuorum 0 = 0
calcMinQuorum n = 1 + floor (fromIntegral n / 2 :: Float)