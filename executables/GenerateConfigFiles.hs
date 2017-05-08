{-# LANGUAGE TupleSections #-}
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
import Data.Default (def)
import Data.String (fromString)
import Control.Lens

import qualified Data.Set as Set
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Data.HashMap.Strict as HM
import qualified Data.ByteString.Char8 as BSC
import System.Directory
import System.Exit

import Kadena.Types hiding (logDir)
import Kadena.Types.Entity
import Apps.Kadena.Client hiding (main)

import Pact.Types.SQLite


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

getUserInput :: forall b. (Show b, Read b) => String -> Maybe b ->
                Maybe (b -> Either String b) -> IO b
getUserInput prompt defaultVal safetyCheck = do
  putStrLn prompt
  hFlush stdout
  input' <- getLine
  if input' == "" && isJust defaultVal
    then do
    putStrLn ("Set to recommended value: " ++ (show $ fromJust defaultVal))
    hFlush stdout
    return $ fromJust defaultVal
    else
    case readMaybe input' of
      Nothing -> do
        putStrLn "Invalid Input, try again"
        hFlush stdout
        getUserInput prompt defaultVal safetyCheck
      Just y -> case safetyCheck of
        Nothing -> return y
        Just f -> case f y of
          Left err -> do
            putStrLn err
            hFlush stdout
            getUserInput prompt defaultVal safetyCheck
          Right y' -> return y'

main :: IO ()
main = do
  runAws <- getArgs
  case runAws of
    [] -> mainLocal
    [v,clustersFile] | v == "--distributed" -> mainAws clustersFile
    err -> putStrLn $ "Invalid args, wanted `` or `--aws path-to-cluster-ip-file` but got: " ++ show err

data ConfigParams = ConfigParams
  { clusterCnt :: !Int
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
  , adminKeyCnt :: !Int
  , entityCnt :: !Int
  } deriving (Show)

data ConfGenMode =
  AWS
  { awsClusterCnt :: !Int } |
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

validate :: (a -> Bool) -> String -> Maybe (a -> Either String a)
validate f msg = Just $ \a -> if f a then Right a else Left msg

getParams :: ConfGenMode -> IO ConfigParams
getParams cfgMode = do
  putStrLn "When a recommended setting is available, press Enter to use it" >> hFlush stdout
  let reqd = validate null "This is required"
  logDir' <- getUserInput
    "[FilePath] Which directory should hold the log files and SQLite DB's? (recommended: ./log)" (Just "./log") reqd
  confDir' <- getUserInput
    "[FilePath] Where should `genconfs` write the configuration files? (recommended: ./conf)" (Just "./conf") reqd
  confDirExists <- doesDirectoryExist confDir'
  unless confDirExists $ do
    absPath' <- makeAbsolute confDir'
    putStrLn ("Warning: " ++ confDir' ++ " does not exist (absPath:" ++ absPath' ++" )")
    hFlush stdout
    mkConfDir' <-
      yesNoToBool <$> getUserInput "[Yes|No] Should we create it? (recommended: Yes)"
        (Just Yes) Nothing
    if mkConfDir'
      then createDirectoryIfMissing True confDir'
      else die "Configuration directory is required and must exist"
  let checkGTE gt = Just $ \x -> if x >= gt then Right x else Left $ "Must be >= " ++ show gt
  clusterCnt' <- case cfgMode of
    LOCAL -> getUserInput "[Integer] Number of consensus servers?" Nothing (checkGTE 3)
    AWS{..} -> return awsClusterCnt
  heartbeat' <- getUserInput
    "[Integer] Leader's heartbeat timeout (in seconds)? (recommended: 2)" (Just 2) $ checkGTE 1
  let elMinRec = (5 * heartbeat')
  electionMin' <- getUserInput
    ("[Integer] Election timeout min in seconds? (recommended: " ++ show elMinRec ++ ")")
    (Just elMinRec) $ checkGTE (2*heartbeat')
  let elMaxRec = (clusterCnt'*2)+electionMin'
  electionMax' <- getUserInput
    ("[Integer] Election timeout max in seconds? (recommended: >=" ++ show elMaxRec ++ ")") (Just elMaxRec) $
    checkGTE (1 + electionMin')
  let aeRepRec = 10000*heartbeat'
  aeRepLimit' <- getUserInput
    ("[Integer] Pending transaction replication limit per heartbeat? (recommended: " ++ show aeRepRec ++ ")")
    (Just aeRepRec) $ checkGTE 1
  let inMemRec = (10*aeRepLimit')
  inMemTxs' <- getUserInput
    ("[Integer] How many committed transactions should be cached? (recommended: " ++ show inMemRec ++ ")" )
    (Just inMemRec) $ checkGTE 0
  ppUsePar' <- sparksThreadsToBool <$> getUserInput
    "[Sparks|Threads] Should the Crypto PreProcessor use spark or green thread based concurrency? (recommended: Sparks)"
    (Just Sparks) Nothing
  ppThreadCnt' <-
    if ppUsePar'
    then getUserInput
      "[Integer] How many transactions should the Crypto PreProcessor work on at once? (recommended: 10)"
      (Just 10) $ checkGTE 1
    else getUserInput
      "[Integer] How many green threads should be allocated to the Crypto PreProcessor? (recommended: 5 to 100)"
      Nothing $ checkGTE 1
  enableWB' <- yesNoToBool <$>
     getUserInput "[Yes|No] Use write-behind backend? (recommended: Yes)" (Just Yes) Nothing
  hostStaticDir' <- yesNoToBool <$>
    getUserInput "[Yes|No] Should each node host the contents of './static' as '<host>:<port>/'? (recommended: Yes)"
    (Just Yes) Nothing
  adminKeyCnt' <- getUserInput
    "[Integer] How many admin key pair(s) should be made? (recommended: 1)"
    (Just 1) $ checkGTE 1
  entityCnt' <- getUserInput
    "[Integer] How many private entities to distribute over cluster? (default: 2, must be >0, <= cluster size)"
    (Just 2) $ validate ((&&) <$> (> 0) <*> (<= clusterCnt')) ("Must be >0, <=" ++ show clusterCnt')
  return $ ConfigParams
    { clusterCnt = clusterCnt'
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
    , adminKeyCnt = adminKeyCnt'
    , entityCnt = entityCnt'
    }

makeAdminKeys :: Int -> IO (Map Alias KeyPair)
makeAdminKeys cnt = do
  adminKeys' <- fmap (\(sk,pk) -> KeyPair pk sk) . makeKeys cnt <$> (newGenIO :: IO SystemRandom)
  let adminAliases = (\i -> Alias $ BSC.pack $ "admin" ++ show i) <$> [0..cnt-1]
  return $ M.fromList $ zip adminAliases adminKeys'

mainAws :: FilePath -> IO ()
mainAws clustersFile = do
  !clusters <- lines <$> readFile clustersFile
  clusterIds <- return $ awsNodes clusters
  clusterKeys <- makeKeys (length clusters) <$> (newGenIO :: IO SystemRandom)
  clusterKeyMaps <- return $ awsKeyMaps clusterIds clusterKeys
  cfgParams@ConfigParams{..} <- getParams AWS { awsClusterCnt = length clusterIds }
  adminKeyPairs <- makeAdminKeys adminKeyCnt
  adminKeys' <- return $ fmap _kpPublicKey adminKeyPairs
  ents <- mkEntities clusterIds entityCnt
  clusterConfs <- return (createClusterConfig cfgParams adminKeys' clusterKeyMaps ents 8000 <$> clusterIds)
  mkConfs confDir clusterConfs adminKeyPairs

mainLocal :: IO ()
mainLocal = do
  cfgParams@ConfigParams{..} <- getParams LOCAL
  adminKeyPairs <- makeAdminKeys adminKeyCnt
  adminKeys' <- return $ fmap _kpPublicKey adminKeyPairs
  clusterKeyMaps <- mkNodes (mkNode "127.0.0.1" 10000 "node") . makeKeys clusterCnt <$> (newGenIO :: IO SystemRandom)
  let nids = M.keys (fst clusterKeyMaps)
  ents <- mkEntities nids entityCnt
  clusterConfs <- return $ zipWith (createClusterConfig cfgParams adminKeys' clusterKeyMaps ents)
                  [8000..] nids
  mkConfs confDir clusterConfs adminKeyPairs


mkConfs :: FilePath -> [Config] -> Map Alias KeyPair -> IO ()
mkConfs confDir clusterConfs adminKeyPairs = do
  mapM_ (\c' -> Y.encodeFile ("conf" </> show (_port $ _nodeId c') ++ "-cluster.yaml") c') clusterConfs
  mapM_ (\(a,kp) -> Y.encodeFile (confDir </> (BSC.unpack $ unAlias a) ++ "-keypair.yaml") kp) $ M.toList adminKeyPairs
  [clientKey] <- makeKeys 1 <$> (newGenIO :: IO SystemRandom)
  Y.encodeFile (confDir </> "client.yaml") . createClientConfig clusterConfs $ clientKey

entNames :: [EntityName]
entNames = ["Alice","Bob","Carol","Dinesh"] ++ ((\a b -> fromString (a:[b])) <$> ['A'..'Z'] <*> ['A'..'Z'])

mkEntities :: [NodeId] -> Int -> IO (Map NodeId EntityConfig)
mkEntities nids ec = do
  kpMap <- fmap M.fromList $ forM (take ec entNames) $ \en -> do
    kps <- (,) <$> genKeyPair <*> genKeyPair
    return (en,kps)
  let mkR (ren,(rstatic,_)) = EntityRemote ren (EntityPublicKey (_ekPublic rstatic))
      ents = (`M.mapWithKey` kpMap) $ \en (static,eph) ->
        EntityConfig
        (EntityLocal en static eph)
        (map mkR $ M.toList $ M.delete en kpMap)
        False
      nodePerEnt = length nids `div` ec
      setHeadSending = set (ix 0 . _2 . ecSending) True
      alloc [] _ = []
      alloc _ [] = error $ "Ran out of entities! Bad entity count: " ++ show ec
      alloc nids' (e:es) = (setHeadSending $ map (,e) $ take nodePerEnt nids') ++ alloc (drop nodePerEnt nids') es
  return $ M.fromList $ alloc nids (M.elems ents)

toAliasMap :: Map NodeId a -> Map Alias a
toAliasMap = M.fromList . map (first _alias) . M.toList

createClusterConfig :: ConfigParams -> (Map Alias PublicKey) -> (Map NodeId PrivateKey, Map NodeId PublicKey) ->
                       (Map NodeId EntityConfig) -> Int -> NodeId -> Config
createClusterConfig cp@ConfigParams{..} adminKeys' (privMap, pubMap) entMap apiP nid = Config
  { _otherNodes           = Set.delete nid $ M.keysSet pubMap
  , _nodeId               = nid
  , _publicKeys           = toAliasMap $ pubMap
  , _adminKeys            = adminKeys'
  , _myPrivateKey         = privMap M.! nid
  , _myPublicKey          = pubMap M.! nid
  , _electionTimeoutRange = (3000000,6000000)
  , _heartbeatTimeout     = 1000000
  , _enableDebug          = True
  , _enablePersistence    = True
  , _pactPersist          = mkPactPersistConfig cp True nid
  , _logRules             = def
  , _apiPort              = apiP
  , _entity               = entMap M.! nid
  , _logDir               = logDir
  , _aeBatchSize          = aeRepLimit
  , _preProcThreadCount   = ppThreadCnt
  , _preProcUsePar        = ppUsePar
  , _inMemTxCache         = inMemTxs
  , _hostStaticDir        = hostStaticDirB
  , _nodeClass            = Active
  }

mkPactPersistConfig :: ConfigParams -> Bool -> NodeId -> PactPersistConfig
mkPactPersistConfig ConfigParams{..} enablePersist NodeId{..} = PactPersistConfig {
    _ppcWriteBehind = enableWB
  , _ppcBackend = if enablePersist
                  then PPBSQLite
                       { _ppbSqliteConfig = SQLiteConfig {
                             dbFile = logDir </> (show $ _alias) ++ "-pact.sqlite"
                           , pragmas = if enableWB then [] else fastNoJournalPragmas } }
                  else PPBInMemory
  }

createClientConfig :: [Config] -> (PrivateKey,PublicKey) -> ClientConfig
createClientConfig clusterConfs (priv,pub) =
    ClientConfig
    { _ccSecretKey = priv
    , _ccPublicKey = pub
    , _ccEndpoints = HM.fromList $ (`map` clusterConfs) $ \n ->
        (show $ _alias (_nodeId n), _host (_nodeId n) ++ ":" ++ show (_apiPort n))
    }
