{-# Language OverloadedStrings #-}

module ConfigChangeFileSpec where

import Control.Monad.Catch
import Control.Monad
import Control.Monad.IO.Class
import qualified Data.Yaml as Y
import Test.Hspec

import Kadena.ConfigChange.Types
import Kadena.Types.Base
import Kadena.Types.Command

import qualified Pact.Types.Command as Pact
import qualified Pact.Types.Crypto as Pact

spec :: Spec
spec = describe "testConfigChangeYaml" testConfigChangeYaml

testConfigChangeYaml :: Spec
testConfigChangeYaml =
    it "Verifies the loading of config change .yaml files" $
        forM_ yamlExamples (\ex -> do
            theResult <- loadYaml $ fst ex
            theResult `shouldBe` (snd ex))

testConfDir :: String
testConfDir = "test-files/conf/"

loadYaml :: FilePath -> IO ConfigChangeApiReq
loadYaml fp =
  either (yamlErr . show) return =<< liftIO (Y.decodeFileEither (testConfDir ++ fp))
    where yamlErr errMsg = throwM . userError $ "Failure reading yaml: " ++ errMsg

yamlExamples :: [(FilePath, ConfigChangeApiReq)]
yamlExamples = [yamlExample1, yamlExample2, yamlExample3]

yamlExample1 :: (FilePath, ConfigChangeApiReq)
yamlExample1 =
  ( "config-change-01.yaml"
  , ConfigChangeApiReq
    { _ylccInfo = clusterChangeInfo1
      , _ylccKeyPairs = testSigs
      , _ylccNonce = Nothing
    }
  )

yamlExample2 :: (FilePath, ConfigChangeApiReq)
yamlExample2 =
  ( "config-change-02.yaml"
  , ConfigChangeApiReq
    { _ylccInfo = clusterChangeInfo2
      , _ylccKeyPairs = testSigs
      , _ylccNonce = Nothing
    }
  )

yamlExample3 :: (FilePath, ConfigChangeApiReq)
yamlExample3 =
  ( "config-change-03.yaml"
  , ConfigChangeApiReq
    { _ylccInfo = clusterChangeInfo3
    , _ylccKeyPairs = testSigs
    , _ylccNonce = Nothing
    }
  )

testSigs :: [Pact.UserSig]
testSigs = [sig1]

sig1 :: Pact.UserSig
sig1 = Pact.UserSig
  { Pact._usScheme = Pact.ED25519
  , Pact._usPubKey = "06c9c56daa8a068e1f19f5578cdf1797b047252e1ef0eb4a1809aa3c2226f61e"
  , Pact._usSig = "7ce4bae38fccfe33b6344b8c260bffa21df085cf033b3dc99b4781b550e1e922"
  }

clusterChangeInfo1, clusterChangeInfo2, clusterChangeInfo3 :: ClusterChangeInfo
clusterChangeInfo1 = ClusterChangeInfo
                       { _cciNewNodeList = nodes013
                       , _cciAddedNodes = []
                       , _cciRemovedNodes = [node2]
                       , _cciState = Transitional }
clusterChangeInfo2 = ClusterChangeInfo
                       { _cciNewNodeList = nodes012
                       , _cciAddedNodes = [node2]
                       , _cciRemovedNodes = [node3]
                       , _cciState = Transitional }
clusterChangeInfo3 = ClusterChangeInfo
                       { _cciNewNodeList = nodes0123
                       , _cciAddedNodes = [node3]
                       , _cciRemovedNodes = []
                       , _cciState = Transitional }

nodes012, nodes013, nodes0123 :: [NodeId]
nodes012 = [node0, node1, node2]
nodes013 = [node0, node1, node3]
nodes0123 = [node0, node1, node2, node3]

node0 :: NodeId
node0 = NodeId
  { _host = "127.0.0.1"
  , _port = 10000
  , _fullAddr = "tcp://127.0.0.1:10000"
  , _alias = "node0" }

node1 :: NodeId
node1 = NodeId
  { _host = "127.0.0.1"
  , _port = 10001
  , _fullAddr = "tcp://127.0.0.1:10001"
  , _alias = "node1" }

node2 :: NodeId
node2 = NodeId
  { _host = "127.0.0.1"
  , _port = 10002
  , _fullAddr = "tcp://127.0.0.1:10002"
  , _alias = "node2" }

node3 :: NodeId
node3 = NodeId
  { _host = "127.0.0.1"
  , _port = 10003
  , _fullAddr = "tcp://127.0.0.1:10003"
  , _alias = "node3" }
