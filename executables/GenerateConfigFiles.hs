{-# LANGUAGE RecordWildCards #-}
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

getUserInput :: forall b. Read b => String -> Maybe (b -> Either String b) -> IO b
getUserInput prompt safetyCheck = do
  putStrLn prompt
  hFlush stdout
  getLine >>= \x -> case readMaybe x of
    Nothing -> putStrLn "Invalid Input, try again" >> hFlush stdout >> getUserInput prompt safetyCheck
    Just y -> case safetyCheck of
      Nothing -> return y
      Just f -> case f y of
        Left err -> putStrLn err >> hFlush stdout >> getUserInput prompt safetyCheck
        Right y' -> return y'

main :: IO ()
main = do
  runAws <- getArgs
  case runAws of
    [] -> mainLocal
    [v,clustersFile,clientsFile] | v == "--aws" -> mainAws clustersFile clientsFile
    err -> putStrLn $ "Invalid args, wanted `` or `--aws path-to-cluster-ip-file path-to-client-ip-file` but got: " ++ show err

data ConfigParams = ConfigParams
  { clusterCnt :: Int
  , clientCnt :: Int
  , aeRepLimit :: Int
  , ppThreadCnt :: Int
  , ppUsePar :: Bool
  , heartbeat :: Int
  , electionMax :: Int
  , electionMin :: Int
  } deriving (Show)

data ConfGenMode =
  AWS {awsClientCnt :: Int, awsClusterCnt :: Int}
  | LOCAL
  deriving (Show, Eq)
data YesNo = Yes | No deriving (Show, Eq, Read)
data SparksThreads = Sparks | Threads deriving (Show, Eq, Read)

_yesNoToBool :: YesNo -> Bool
_yesNoToBool Yes = True
_yesNoToBool No = False

sparksThreadsToBool :: SparksThreads -> Bool
sparksThreadsToBool Sparks = True
sparksThreadsToBool Threads = False

getParams :: ConfGenMode -> IO ConfigParams
getParams cfgMode = do
  let checkGTE gt = Just $ \x -> if x >= gt then Right x else Left $ "Must be >= " ++ show gt
  (clusterCnt',clientCnt') <- case cfgMode of
    LOCAL -> (,) <$> getUserInput "[Integer] Number of consensus servers?" (checkGTE 3)
                 <*> getUserInput "[Integer] Number of clients?" Nothing
    AWS{..} -> return (awsClusterCnt,awsClientCnt)
  aeRepLimit' <- getUserInput "[Integer] Pending transaction replication limit per heartbeat? (recommended: 12000)" $ checkGTE 1
  ppUsePar' <- sparksThreadsToBool <$> getUserInput "[Sparks|Threads] Should the Crypto PreProcessor use spark or green thread based parallelism? (recommended: Sparks)" Nothing
  ppThreadCnt' <- if ppUsePar'
                 then getUserInput "[Integer] How many transactions should the Crypto PreProcessor work on at once? (recommended: 100)" $ checkGTE 1
                 else getUserInput "[Integer] How many green threads should be allocated to the Crypto PreProcessor? (recommended: 5 to 100)" $ checkGTE 1
  heartbeat' <- getUserInput "[Integer] Leader's heartbeat timeout (in seconds)? (recommended: 2)" $ checkGTE 1
  electionMin' <- getUserInput ("[Integer] Election timeout min in seconds? (recommended: " ++ show (5*heartbeat') ++ ")") $ checkGTE (2*heartbeat')
  electionMax' <- getUserInput ("[Integer] Election timeout max in seconds? (recommended: >=" ++ show ((clusterCnt'*2)+electionMin') ++ ")") $ checkGTE (1 + electionMin')
  return $ ConfigParams
    { clusterCnt = clusterCnt'
    , clientCnt = clientCnt'
    , aeRepLimit = aeRepLimit'
    , ppThreadCnt = ppThreadCnt'
    , ppUsePar = ppUsePar'
    , heartbeat = heartbeat' * 1000000
    , electionMax = electionMax' * 1000000
    , electionMin = electionMin' * 1000000
    }

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
  cfgParams <- getParams AWS {awsClientCnt = length clientIds, awsClusterCnt = length clusterIds}
  clusterConfs <- return (createClusterConfig cfgParams clusterKeyMaps (snd clientKeyMaps) 8000 <$> clusterIds)
  clientConfs <- return (createClientConfig clusterConfs clientKeyMaps <$> clientIds)
  mapM_ (\c' -> Y.encodeFile ("aws-conf" </> _host (_nodeId c') ++ "-cluster-aws.yaml") c') clusterConfs
  mapM_ (\(ci,c') -> Y.encodeFile ("aws-conf" </> show ci ++ "-client-aws.yaml") c') $ zip clientIds clientConfs

mainLocal :: IO ()
mainLocal = do
  cfgParams@ConfigParams{..} <- getParams LOCAL
  g <- newGenIO :: IO SystemRandom
  let clusterKeyMaps = mkNodes (mkNode "127.0.0.1" 10000 "node") $ makeKeys clusterCnt g
      clientKeyMaps = mkNodes (mkNode "127.0.0.1" 11000 "client") $ makeKeys clientCnt g
      clusterConfs = zipWith (createClusterConfig cfgParams clusterKeyMaps (snd clientKeyMaps)) [8000..] (M.keys (fst clusterKeyMaps))
  clientConfs <- return (createClientConfig clusterConfs clientKeyMaps <$> M.keys (fst clientKeyMaps))
  mapM_ (\c' -> Y.encodeFile ("conf" </> show (_port $ _nodeId c') ++ "-cluster.yaml") c') clusterConfs
  mapM_ (\(i :: Int,c') -> Y.encodeFile ("conf" </> "client" ++ show i ++ "-client.yaml") c') (zip [0..] clientConfs)

toAliasMap :: Map NodeId a -> Map Alias a
toAliasMap = M.fromList . map (first _alias) . M.toList

createClusterConfig :: ConfigParams -> (Map NodeId PrivateKey, Map NodeId PublicKey) -> Map NodeId PublicKey
  -> Int -> NodeId -> Config
createClusterConfig ConfigParams{..} (privMap, pubMap) clientPubMap apiP nid = Config
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
  , _apiPort              = apiP
  , _logSqliteDir         = Just $ "./log/" ++ BSC.unpack (unAlias $ _alias nid)
  , _entity               = EntityInfo "me"
  , _dbFile               = Just $ "./log/" ++ BSC.unpack (unAlias $ _alias nid) ++ "-pactdb.sqlite"
  , _aeBatchSize          = aeRepLimit
  , _preProcThreadCount   = ppThreadCnt
  , _preProcUsePar        = ppUsePar
  }

createClientConfig :: [Config] -> (Map NodeId PrivateKey, Map NodeId PublicKey) -> NodeId -> ClientConfig
createClientConfig clusterConfs (privMap, pubMap) nid =
    ClientConfig
    { _ccSecretKey = privMap M.! nid
    , _ccPublicKey = pubMap M.! nid
    , _ccEndpoints = HM.fromList $ map (\n -> (show $ _alias (_nodeId n), _host (_nodeId n) ++ ":" ++ show (_apiPort n))) clusterConfs
    }
