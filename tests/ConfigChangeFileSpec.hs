{-# Language OverloadedStrings #-}

module ConfigChangeFileSpec where

import Control.Monad.Catch
import Control.Monad
import Control.Monad.IO.Class
import qualified Crypto.Ed25519.Pure as Ed25519
import Data.Either
import qualified Data.Yaml as Y
import Test.Hspec

import qualified Kadena.Types.Crypto as KC
import Kadena.Types.Base
import Kadena.Types.Command

import Pact.Types.Util (fromText')

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
      , _ylccKeyPairs = keyPairs
      , _ylccNonce = Nothing
      }
  )

yamlExample2 :: (FilePath, ConfigChangeApiReq)
yamlExample2 =
  ( "config-change-02.yaml"
  , ConfigChangeApiReq
    { _ylccInfo = clusterChangeInfo2
      , _ylccKeyPairs = keyPairs
      , _ylccNonce = Nothing
    }
  )

yamlExample3 :: (FilePath, ConfigChangeApiReq)
yamlExample3 =
  ( "config-change-03.yaml"
  , ConfigChangeApiReq
      { _ylccInfo = clusterChangeInfo3
      , _ylccKeyPairs = keyPairs
      , _ylccNonce = Nothing } )

keyPairs :: [KC.KeyPair]
keyPairs = foldr f [] keyPairs' where
    f ::  (Ed25519.PublicKey, Ed25519.PrivateKey) -> [KC.KeyPair] -> [KC.KeyPair]
    f (pk, sk) r = KC.KeyPair {KC._kpPublicKey = pk, KC._kpPrivateKey = sk} : r

keyPairs' :: [(Ed25519.PublicKey, Ed25519.PrivateKey)]
keyPairs' =
  let eList = [keyPair1]
      pairs = rights (fmap fst eList) `zip` rights (fmap snd eList)
      in if length pairs /= length eList
            then fail "Error creating key pairs"
            else pairs

keyPair1 :: (Either String Ed25519.PublicKey, Either String Ed25519.PrivateKey)
keyPair1 =
  ( fromText' "31736b5c851176e5dff830df44bf0c88fb0da5522a9d9e3ac10ff0c433528c7d"
  , fromText' "b737c6b7d950b9ecbd7e2e187d05b07fc8f3ec2dab8220f19f7b4b68ae6d9319" )

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
