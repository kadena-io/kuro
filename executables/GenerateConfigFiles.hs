{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE PackageImports #-}

module Main (main) where

import Control.Arrow
import "crypto-api" Crypto.Random
import Data.Ratio
import Crypto.Ed25519.Pure
import Text.Read
import Data.Thyme.Clock
import System.IO
import System.FilePath
import System.Environment
import qualified Data.Yaml as Y
import Data.Word

import qualified Data.Set as Set
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Data.HashMap.Strict as HM
import qualified Data.ByteString.Char8 as BSC

import Kadena.Types
import Apps.Kadena.Client hiding (main)


mkNodes :: (Word64 -> NodeId) -> [(PrivateKey,PublicKey)] -> (Map NodeId PrivateKey, Map NodeId PublicKey)
mkNodes nodeG keys = (ss,ps) where
    ps = M.fromList $ map (second snd) ns
    ss = M.fromList $ map (second fst) ns
    ns = zipWith (\a i -> (nodeG i,a)) keys [0..]

mkNode :: String -> Word64 -> String -> Word64 -> NodeId
mkNode host msgPortRoot namePrefix n =
    let np = msgPortRoot+n in
    NodeId host np ("tcp://" ++ host ++ ":" ++ show np) (Alias (BSC.pack $ namePrefix ++ show n))

makeKeys :: CryptoRandomGen g => Int -> g -> [(PrivateKey,PublicKey)]
makeKeys 0 _ = []
makeKeys n g = case generateKeyPair g of
  Left err -> error $ show err
  Right (p,priv,g') -> (p,priv) : makeKeys (n-1) g'

awsNodes :: [String] -> [NodeId]
awsNodes = fmap (\h -> NodeId h 10000 ("tcp://" ++ h ++ ":10000") $ Alias (BSC.pack h))

awsKeyMaps :: [NodeId] -> [(PrivateKey, PublicKey)] -> (Map NodeId PrivateKey, Map NodeId PublicKey)
awsKeyMaps nodes' ls = (M.fromList $ zip nodes' (fst <$> ls), M.fromList $ zip nodes' (snd <$> ls))

getUserInput :: forall b. Read b => String -> IO b
getUserInput prompt = do
  putStrLn prompt
  hFlush stdout
  getLine >>= \x -> case readMaybe x of
    Nothing -> error "Invalid Input"
    Just y -> return y

main :: IO ()
main = do
  runAws <- getArgs
  case runAws of
    [] -> mainLocal
    [v,clustersFile,clientsFile] | v == "--aws" -> mainAws clustersFile clientsFile
    err -> putStrLn $ "Invalid args, wanted `` or `--aws path-to-cluster-ip-file path-to-client-ip-file` but got: " ++ show err

mainAws :: FilePath -> FilePath -> IO ()
mainAws clustersFile clientsFile = do
  !clusters <- lines <$> readFile clustersFile
  !clients <- lines <$> readFile clientsFile
  g <- newGenIO :: IO SystemRandom
  clusterIds <- return $ awsNodes clusters
  clusterKeys <- return $ makeKeys (length clusters) g
  clusterKeyMaps <- return $ awsKeyMaps clusterIds clusterKeys
  g' <- newGenIO :: IO SystemRandom
  clientIds <- return $ awsNodes clients
  clientKeys <- return $ makeKeys (length clients) g'
  clientKeyMaps <- return $ awsKeyMaps clientIds clientKeys
  aeSize <- getUserInput "Max AE Batch Size?"
  ppThreads <- getUserInput "PreProcessor: Thread Count?"
  ppUsePar <- getUserInput "PreProcessor: Use Parallel.Strategies (True/False)?"
  clusterConfs <- return (createClusterConfig True aeSize ppThreads ppUsePar clusterKeyMaps (snd clientKeyMaps) 8000 <$> clusterIds)
  clientConfs <- return (createClientConfig clusterConfs clientKeyMaps <$> clientIds)
  mapM_ (\c' -> Y.encodeFile
          ("aws-conf" </> _host (_nodeId c') ++ "-cluster-aws.yaml")
          (c' { _enableAwsIntegration = False
              , _electionTimeoutRange = (10000000,20000000)
              , _heartbeatTimeout = 2000000
              })
        ) clusterConfs
  mapM_ (\(ci,c') -> Y.encodeFile
          ("aws-conf" </> show ci ++ "-client-aws.yaml")
          c'
        ) $ zip clientIds clientConfs

mainLocal :: IO ()
mainLocal = do
  n <- getUserInput "Number of cluster nodes?"
  c <- getUserInput "Number of client nodes?"
  aeSize <- getUserInput "Max AE Batch Size?"
  ppThreads <- getUserInput "PreProcessor: Thread Count?"
  ppUsePar <- getUserInput "PreProcessor: Use Parallel.Strategies (True/False)?"
  df <- getUserInput "Enable logging for Followers (True/False)?"
  g <- newGenIO :: IO SystemRandom
  let clusterKeyMaps = mkNodes (mkNode "127.0.0.1" 10000 "node") $ makeKeys n g
      clientKeyMaps = mkNodes (mkNode "127.0.0.1" 11000 "client") $ makeKeys c g
      clusterConfs = zipWith (createClusterConfig df aeSize ppThreads ppUsePar clusterKeyMaps (snd clientKeyMaps)) [8000..] (M.keys (fst clusterKeyMaps))
  clientConfs <- return (createClientConfig clusterConfs clientKeyMaps <$> M.keys (fst clientKeyMaps))
  mapM_ (\c' -> Y.encodeFile ("conf" </> show (_port $ _nodeId c') ++ "-cluster.yaml") c') clusterConfs
  mapM_ (\(i :: Int,c') -> Y.encodeFile ("conf" </> "client" ++ show i ++ "-client.yaml") c') (zip [0..] clientConfs)

toAliasMap :: Map NodeId a -> Map Alias a
toAliasMap = M.fromList . map (first _alias) . M.toList

createClusterConfig :: Bool -> Int -> Int -> Bool
  -> (Map NodeId PrivateKey, Map NodeId PublicKey) -> Map NodeId PublicKey
  -> Int -> NodeId -> Config
createClusterConfig debugFollower aeBatchSize' preProcThreadCount' preProcUsePar' (privMap, pubMap) clientPubMap apiP nid = Config
  { _otherNodes           = Set.delete nid $ M.keysSet pubMap
  , _nodeId               = nid
  , _publicKeys           = toAliasMap $ pubMap
  , _clientPublicKeys     = toAliasMap $ clientPubMap
  , _myPrivateKey         = privMap M.! nid
  , _myPublicKey          = pubMap M.! nid
  , _electionTimeoutRange = (3000000,6000000)
  , _heartbeatTimeout     = 1000000
  , _batchTimeDelta       = fromSeconds' (1%100) -- 10ms
  , _enableDebug          = True
  , _clientTimeoutLimit   = 50000
  , _dontDebugFollower    = not debugFollower
  , _apiPort              = apiP
  , _logSqliteDir         = Just $ "./log/" ++ BSC.unpack (unAlias $ _alias nid)
  , _enableAwsIntegration = False
  , _entity               = EntityInfo "me"
  , _dbFile               = Just $ "./log/" ++ BSC.unpack (unAlias $ _alias nid) ++ "-pactdb.sqlite"
  , _aeBatchSize          = aeBatchSize'
  , _preProcThreadCount   = preProcThreadCount'
  , _preProcUsePar        = preProcUsePar'
  }

createClientConfig :: [Config] -> (Map NodeId PrivateKey, Map NodeId PublicKey) -> NodeId -> ClientConfig
createClientConfig clusterConfs (privMap, pubMap) nid =
    ClientConfig
    { _ccSecretKey = privMap M.! nid
    , _ccPublicKey = pubMap M.! nid
    , _ccEndpoints = HM.fromList $ map (\n -> (show $ _alias (_nodeId n), _host (_nodeId n) ++ ":" ++ show (_apiPort n))) clusterConfs
    }
{-
Config
  { _otherNodes           = M.keysSet clusterPubMap
  , _nodeId               = nid
  , _publicKeys           = toAliasMap $ clusterPubMap
  , _clientPublicKeys     = toAliasMap $ pubMap
  , _myPrivateKey         = privMap M.! nid
  , _myPublicKey          = pubMap M.! nid
  , _electionTimeoutRange = (3000000,6000000)
  , _heartbeatTimeout     = 1000000
  , _batchTimeDelta       = fromSeconds' (1%100) -- default to 10ms
  , _enableDebug          = False
  , _clientTimeoutLimit   = 50000
  , _dontDebugFollower    = not debugFollower
  , _apiPort              = 8000
  , _logSqlitePath        = ""
  , _enableAwsIntegration = False
  , _entity               = EntityInfo "client"
  , _dbFile               = Nothing
  }
-}
