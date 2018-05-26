{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module EvidenceSpec where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Test.Hspec

import Kadena.Evidence.Service (checkPartialEvidence')
import Kadena.Types.Base (Alias (..), LogIndex(..), NodeId(..))


spec :: Spec
spec = describe "testPartialEvidence" testPartialEvidence



testPartialEvidence :: Spec
testPartialEvidence = do
  it "testSuccess1" $
    (checkPartialEvidence'
      nodeIdSet123 -- tNodeIds
      Set.empty -- tChgToNodeIds
      3 -- tEvNeeded
      0 -- tChgToEvNeeded
      logToNodesMapA -- tPartialEv
      ) `shouldBe` Right (LogIndex 2)
  it "testSuccess2" $
    (checkPartialEvidence'
      nodeIdSet123 -- tNodeIds
      nodeIdSet2345 -- tChgToNodeIds
      3 -- tEvNeeded
      4 -- tChgToEvNeeded
      logToNodesMapB -- tPartialEv
      ) `shouldBe` Right (LogIndex 2)
  it "testSuccess3" $
    (checkPartialEvidence'
      nodeIdSet2345 -- tNodeIds
      Set.empty -- tChgToNodeIds
      4 -- tEvNeeded
      0 -- tChgToEvNeeded
      logToNodesMapC -- tPartialEv
      ) `shouldBe` Right (LogIndex 1)
  it "testMissing4" $
    (checkPartialEvidence'
      nodeIdSet123 -- tNodeIds
      nodeIdSet2345 -- tChgToNodeIds
      3 -- tEvNeeded
      4 -- tChgToEvNeeded
      logToNodesMapD -- tPartialEv
      ) `shouldBe` Left [0, 2]



logToNodesMapA, logToNodesMapB, logToNodesMapC, logToNodesMapD :: Map LogIndex (Set NodeId)
logToNodesMapA = Map.fromList
  [ (LogIndex 1, nodeIdSet0)
  , (LogIndex 2, nodeIdSet12)
  , (LogIndex 3, nodeIdSet3) ]
logToNodesMapB = Map.fromList
  [ (LogIndex 1, nodeIdSet0)
  , (LogIndex 2, nodeIdSet1)
  , (LogIndex 3, nodeIdSet2345) ]
logToNodesMapC = Map.fromList
  [ (LogIndex 1, nodeIdSet45)
  , (LogIndex 2, nodeIdSet12)
  , (LogIndex 3, nodeIdSet3) ]
logToNodesMapD = Map.fromList
  [ (LogIndex 1, nodeIdSet0)
  , (LogIndex 2, nodeIdSet12)
  , (LogIndex 3, nodeIdSet3) ]

nodeIdSet123, nodeIdSet2345, nodeIdSet45, nodeIdSet12, nodeIdSet3, nodeIdSet1, nodeIdSet0 :: Set NodeId
nodeIdSet123 = Set.fromList [nodeId1, nodeId2, nodeId3]
nodeIdSet2345 = Set.fromList [nodeId2, nodeId3, nodeId4, nodeId5]
nodeIdSet45 = Set.fromList [nodeId4, nodeId5]
nodeIdSet12 = Set.fromList [nodeId1, nodeId2]
nodeIdSet1 = Set.fromList [nodeId1]
nodeIdSet3 = Set.fromList [nodeId3]
nodeIdSet0 = Set.fromList [nodeId0]

nodeId0, nodeId1, nodeId2, nodeId3, nodeId4, nodeId5 :: NodeId
nodeId0 = NodeId { _host = "host0", _port = 1000, _fullAddr = "fullAddr0", _alias = Alias {unAlias = "alias0"} }
nodeId1 = NodeId { _host = "host1", _port = 1001, _fullAddr = "fullAddr1", _alias = Alias {unAlias = "alias1"} }
nodeId2 = NodeId { _host = "host2", _port = 1002, _fullAddr = "fullAddr2", _alias = Alias {unAlias = "alias2"} }
nodeId3 = NodeId { _host = "host3", _port = 1003, _fullAddr = "fullAddr3", _alias = Alias {unAlias = "alias3"} }
nodeId4 = NodeId { _host = "host4", _port = 1004, _fullAddr = "fullAddr4", _alias = Alias {unAlias = "alias4"} }
nodeId5 = NodeId { _host = "host5", _port = 1005, _fullAddr = "fullAddr5", _alias = Alias {unAlias = "alias5"} }
