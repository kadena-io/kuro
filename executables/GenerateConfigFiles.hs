{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE PackageImports #-}

module Main (main) where

import Control.Arrow
import Control.Monad
import "crypto-api" Crypto.Random
import Crypto.Ed25519.Pure
import Text.Read
import System.IO
import System.FilePath
import System.Environment
import qualified Data.Yaml as Y
import Data.Word
import Data.Maybe (fromJust, isJust)

import qualified Data.Set as Set
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Data.HashMap.Strict as HM
import qualified Data.ByteString.Char8 as BSC
import System.Directory
import System.Exit

import Kadena.Types hiding (logDir)
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

getUserInput :: forall b. (Show b, Read b) => String -> Maybe b -> Maybe (b -> Either String b) -> IO b
getUserInput prompt defaultVal safetyCheck = do
  putStrLn prompt
  hFlush stdout
  input' <- getLine
  if input' == "" && isJust defaultVal
  then do
    putStrLn ("Set to recommended value: " ++ (show $ fromJust defaultVal)) >> hFlush stdout
    return $ fromJust defaultVal
  else
    case readMaybe input' of
      Nothing -> putStrLn "Invalid Input, try again" >> hFlush stdout >> getUserInput prompt defaultVal safetyCheck
      Just y -> case safetyCheck of
        Nothing -> return y
        Just f -> case f y of
          Left err -> putStrLn err >> hFlush stdout >> getUserInput prompt defaultVal safetyCheck
          Right y' -> return y'

main :: IO ()
main = do
  runAws <- getArgs
  case runAws of
    [] -> mainLocal
    [v,clustersFile,clientsFile] | v == "--distributed" -> mainAws clustersFile clientsFile
    err -> putStrLn $ "Invalid args, wanted `` or `--aws path-to-cluster-ip-file path-to-client-ip-file` but got: " ++ show err

data ConfigParams = ConfigParams
  { clusterCnt :: !Int
  , clientCnt :: !Int
  , aeRepLimit :: !Int
  , ppThreadCnt :: !Int
  , ppUsePar :: !Bool
  , heartbeat :: !Int
  , electionMax :: !Int
  , electionMin :: !Int
  , inMemTxs :: !Int
  , logDir :: !FilePath
  , confDir :: !FilePath
  , enableWB :: !Bool
  , hostStaticDirB :: !Bool
  } deriving (Show)

data ConfGenMode =
  AWS
  { awsClientCnt :: !Int
  , awsClusterCnt :: !Int } |
  LOCAL
  deriving (Show, Eq)
data YesNo = Yes | No deriving (Show, Eq, Read)
data SparksThreads = Sparks | Threads deriving (Show, Eq, Read)

yesNoToBool :: YesNo -> Bool
yesNoToBool Yes = True
yesNoToBool No = False

sparksThreadsToBool :: SparksThreads -> Bool
sparksThreadsToBool Sparks = True
sparksThreadsToBool Threads = False

getParams :: ConfGenMode -> IO ConfigParams
getParams cfgMode = do
  putStrLn "When a recommended setting is available, press Enter to use it" >> hFlush stdout
  logDir' <- getUserInput "[FilePath] Which directory should hold the log files and SQLite DB's? (recommended: ./log)" (Just "./log") $ Just (\(x::FilePath)-> if null x then Left "This is required" else Right x)
  confDir' <- getUserInput "[FilePath] Where should `genconfs` write the configuration files? (recommended: ./conf)" (Just "./conf") $ Just (\(x::FilePath)-> if null x then Left "This is required" else Right x)
  confDirExists <- doesDirectoryExist confDir'
  unless confDirExists $ do
    absPath' <- makeAbsolute confDir'
    putStrLn ("Warning: " ++ confDir' ++ " does not exist (absPath:" ++ absPath' ++" )") >> hFlush stdout
    mkConfDir' <- yesNoToBool <$> getUserInput "[Yes|No] Should we create it? (recommended: Yes)" (Just Yes) Nothing
    if mkConfDir'
      then createDirectoryIfMissing True confDir'
      else die "Configuration directory is required and must exist"
  let checkGTE gt = Just $ \x -> if x >= gt then Right x else Left $ "Must be >= " ++ show gt
  (clusterCnt',clientCnt') <- case cfgMode of
    LOCAL -> (,) <$> getUserInput "[Integer] Number of consensus servers?" Nothing (checkGTE 3)
                 <*> getUserInput "[Integer] Number of clients?" Nothing Nothing
    AWS{..} -> return (awsClusterCnt,awsClientCnt)
  heartbeat' <- getUserInput "[Integer] Leader's heartbeat timeout (in seconds)? (recommended: 2)" (Just 2) $ checkGTE 1
  let elMinRec = (5 * heartbeat')
  electionMin' <- getUserInput ("[Integer] Election timeout min in seconds? (recommended: " ++ show elMinRec ++ ")") (Just elMinRec) $ checkGTE (2*heartbeat')
  let elMaxRec = (clusterCnt'*2)+electionMin'
  electionMax' <- getUserInput ("[Integer] Election timeout max in seconds? (recommended: >=" ++ show elMaxRec ++ ")") (Just elMaxRec) $ checkGTE (1 + electionMin')
  let aeRepRec = 10000*heartbeat'
  aeRepLimit' <- getUserInput ("[Integer] Pending transaction replication limit per heartbeat? (recommended: " ++ show aeRepRec ++ ")") (Just aeRepRec) $ checkGTE 1
  let inMemRec = (10*aeRepLimit')
  inMemTxs' <- getUserInput ("[Integer] How many committed transactions should be cached? (recommended: " ++ show inMemRec ++ ")" ) (Just inMemRec) $ checkGTE 0
  ppUsePar' <- sparksThreadsToBool <$> getUserInput "[Sparks|Threads] Should the Crypto PreProcessor use spark or green thread based concurrency? (recommended: Sparks)" (Just Sparks) Nothing
  ppThreadCnt' <- if ppUsePar'
                  then getUserInput "[Integer] How many transactions should the Crypto PreProcessor work on at once? (recommended: 100)" (Just 100) $ checkGTE 1
                  else getUserInput "[Integer] How many green threads should be allocated to the Crypto PreProcessor? (recommended: 5 to 100)" Nothing $ checkGTE 1
  enableWB' <- yesNoToBool <$> getUserInput "[Yes|No] Use write-behind backend? (recommended: Yes)" (Just Yes) Nothing
  hostStaticDir' <- yesNoToBool <$> getUserInput "[Yes|No] Should each node host the contents of './static' as '<host>:<port>/'? (recommended: Yes)" (Just Yes) Nothing
  return $ ConfigParams
    { clusterCnt = clusterCnt'
    , clientCnt = clientCnt'
    , aeRepLimit = aeRepLimit'
    , ppThreadCnt = ppThreadCnt'
    , ppUsePar = ppUsePar'
    , heartbeat = heartbeat' * 1000000
    , electionMax = electionMax' * 1000000
    , electionMin = electionMin' * 1000000
    , inMemTxs = inMemTxs'
    , logDir = logDir'
    , confDir = confDir'
    , enableWB = enableWB'
    , hostStaticDirB = hostStaticDir'
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
  cfgParams@ConfigParams{..} <- getParams AWS {awsClientCnt = length clientIds, awsClusterCnt = length clusterIds}
  clusterConfs <- return (createClusterConfig cfgParams clusterKeyMaps 8000 <$> clusterIds)
  clientConfs <- return (createClientConfig clusterConfs clientKeyMaps <$> clientIds)
  mapM_ (\c' -> Y.encodeFile (confDir </> _host (_nodeId c') ++ "-server.yaml") c') clusterConfs
  mapM_ (\(ci,c') -> Y.encodeFile (confDir </> _host ci ++ "-client.yaml") c') $ zip clientIds clientConfs

mainLocal :: IO ()
mainLocal = do
  cfgParams@ConfigParams{..} <- getParams LOCAL
  g <- newGenIO :: IO SystemRandom
  let clusterKeyMaps = mkNodes (mkNode "127.0.0.1" 10000 "node") $ makeKeys clusterCnt g
      clientKeyMaps = mkNodes (mkNode "127.0.0.1" 11000 "client") $ makeKeys clientCnt g
      clusterConfs = zipWith (createClusterConfig cfgParams clusterKeyMaps) [8000..] (M.keys (fst clusterKeyMaps))
  clientConfs <- return (createClientConfig clusterConfs clientKeyMaps <$> M.keys (fst clientKeyMaps))
  mapM_ (\c' -> Y.encodeFile ("conf" </> show (_port $ _nodeId c') ++ "-cluster.yaml") c') clusterConfs
  mapM_ (\(i :: Int,c') -> Y.encodeFile ("conf" </> "client" ++ show i ++ "-client.yaml") c') (zip [0..] clientConfs)

toAliasMap :: Map NodeId a -> Map Alias a
toAliasMap = M.fromList . map (first _alias) . M.toList

createClusterConfig :: ConfigParams -> (Map NodeId PrivateKey, Map NodeId PublicKey) -> Int -> NodeId -> Config
createClusterConfig ConfigParams{..} (privMap, pubMap) apiP nid = Config
  { _otherNodes           = Set.delete nid $ M.keysSet pubMap
  , _nodeId               = nid
  , _publicKeys           = toAliasMap $ pubMap
  , _myPrivateKey         = privMap M.! nid
  , _myPublicKey          = pubMap M.! nid
  , _electionTimeoutRange = (3000000,6000000)
  , _heartbeatTimeout     = 1000000
  , _enableDebug          = True
  , _enablePersistence    = True
  , _enableWriteBehind    = enableWB
  , _apiPort              = apiP
  , _entity               = EntityInfo "me"
  , _logDir               = logDir
  , _aeBatchSize          = aeRepLimit
  , _preProcThreadCount   = ppThreadCnt
  , _preProcUsePar        = ppUsePar
  , _inMemTxCache         = inMemTxs
  , _hostStaticDir        = hostStaticDirB
  }

createClientConfig :: [Config] -> (Map NodeId PrivateKey, Map NodeId PublicKey) -> NodeId -> ClientConfig
createClientConfig clusterConfs (privMap, pubMap) nid =
    ClientConfig
    { _ccSecretKey = privMap M.! nid
    , _ccPublicKey = pubMap M.! nid
    , _ccEndpoints = HM.fromList $ map (\n -> (show $ _alias (_nodeId n), _host (_nodeId n) ++ ":" ++ show (_apiPort n))) clusterConfs
    }
