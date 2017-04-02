{-# LANGUAGE BangPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}

module Kadena.Types.Config
  ( Config(..), otherNodes, nodeId, electionTimeoutRange, heartbeatTimeout
  , enableDebug, publicKeys, myPrivateKey, enableWriteBehind
  , myPublicKey, apiPort, hostStaticDir
  , logDir, entity, nodeClass, adminKeys
  , aeBatchSize, preProcThreadCount, preProcUsePar
  , inMemTxCache, enablePersistence
  , KeySet(..), ksCluster, confToKeySet
  , EntityInfo(..),entName
  , ConfigUpdateCommand(..)
  , ConfigUpdate(..), cuCmd, cuHash, cuSigs
  , ProcessedConfigUpdate(..), processConfigUpdate
  , ConfigUpdateResult(..)
  , KeyPair(..), getNewKeyPair, execConfigUpdateCmd
  , GlobalConfigTMVar
  , GlobalConfig(..), gcVersion, gcConfig
  , initGlobalConfigTMVar, mutateConfig, getConfigWhenNew
  , ConfigUpdater(..), runConfigUpdater
  , readCurrentConfig
  ) where

import Control.Concurrent.STM
import Control.Lens hiding (Index, (|>))
import Control.Monad

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Text.Read (readMaybe)

import Data.Aeson
import Data.Aeson.Types
import Data.Thyme.Clock
import Data.Thyme.Time.Core ()
import GHC.Generics hiding (from)
import Data.Serialize
import Data.Default
import qualified Data.Yaml as Y

import Pact.Types.Util

import Kadena.Types.Base

data EntityInfo = EntityInfo {
      _entName :: Text
} deriving (Eq,Show,Generic)
$(makeLenses ''EntityInfo)
instance ToJSON EntityInfo where
  toJSON = lensyToJSON 4
instance FromJSON EntityInfo where
  parseJSON = lensyParseJSON 4

data Config = Config
  { _otherNodes           :: !(Set NodeId)
  , _nodeId               :: !NodeId
  , _publicKeys           :: !(Map Alias PublicKey)
  , _adminKeys            :: !(Map Alias PublicKey)
  , _myPrivateKey         :: !PrivateKey
  , _myPublicKey          :: !PublicKey
  , _electionTimeoutRange :: !(Int,Int)
  , _heartbeatTimeout     :: !Int
  , _enableDebug          :: !Bool
  , _apiPort              :: !Int
  , _entity               :: !EntityInfo
  , _logDir               :: !FilePath
  , _enablePersistence    :: !Bool
  , _enableWriteBehind    :: !Bool
  , _aeBatchSize          :: !Int
  , _preProcThreadCount   :: !Int
  , _preProcUsePar        :: !Bool
  , _inMemTxCache         :: !Int -- how many committed transactions should we keep in memory (with the rest on disk)
  , _hostStaticDir        :: !Bool
  , _nodeClass            :: !NodeClass
  }
  deriving (Show, Generic)
makeLenses ''Config

instance ToJSON NominalDiffTime where
  toJSON = toJSON . show . toSeconds'
instance FromJSON NominalDiffTime where
  parseJSON (String s) = case readMaybe $ Text.unpack s of
    Just s' -> return $ fromSeconds' s'
    Nothing -> mzero
  parseJSON _ = mzero
instance ToJSON Config where
  toJSON = lensyToJSON 1
instance FromJSON Config where
  parseJSON = lensyParseJSON 1

data KeySet = KeySet
  { _ksCluster :: !(Map Alias PublicKey)
  } deriving (Show, Eq, Ord)
makeLenses ''KeySet
instance Default KeySet where
  def = KeySet Map.empty

confToKeySet :: Config -> KeySet
confToKeySet Config{..} = KeySet
  { _ksCluster = _publicKeys}

data ConfigUpdateCommand =
  AddNode
    { _cucNodeId :: !NodeId
    , _cucNodeClass :: !NodeClass
    , _cucPublicKey :: !PublicKey } |
  RemoveNode
    { _cucNodeId :: !NodeId } |
  NodeToPassive
    { _cucNodeId :: !NodeId } |
  NodeToActive
    { _cucNodeId :: !NodeId } |
  UpdateNodeKey
    { _cucAlias :: !Alias
    , _cucPublicKey :: !PublicKey
    , _cucKeyPairPath :: !FilePath} |
  AddAdminKey
    { _cucAlias :: !Alias
    , _cucPublicKey :: !PublicKey } |
  UpdateAdminKey
    { _cucAlias :: !Alias
    , _cucPublicKey :: !PublicKey } |
  RemoveAdminKey
    { _cucAlias :: !Alias } |
  RotateLeader
    { _cucTerm :: !Term }
  deriving (Show, Eq, Ord, Generic, Serialize)

confUpdateJsonOptions :: Int -> Options
confUpdateJsonOptions n = defaultOptions
  { fieldLabelModifier = lensyConstructorToNiceJson n
  , sumEncoding = ObjectWithSingleField }

instance ToJSON ConfigUpdateCommand where
  toJSON = genericToJSON (confUpdateJsonOptions 4)
instance FromJSON ConfigUpdateCommand where
  parseJSON = genericParseJSON (confUpdateJsonOptions 4)

data ConfigUpdate a = ConfigUpdate
  { _cuHash :: !Hash
  , _cuSigs :: !(Map PublicKey Signature)
  , _cuCmd :: !a
  } deriving (Show, Eq, Ord, Generic, Serialize)
makeLenses ''ConfigUpdate
instance (ToJSON a) => ToJSON (ConfigUpdate a) where
  toJSON = lensyToJSON 3
instance (FromJSON a) => FromJSON (ConfigUpdate a) where
  parseJSON = lensyParseJSON 3

processConfigUpdate :: ConfigUpdate ByteString -> ProcessedConfigUpdate
processConfigUpdate ConfigUpdate{..} =
  let
    hash' = hash _cuCmd
    sigs = (\(k,s) -> (valid hash' k s,k,s)) <$> Map.toList _cuSigs
    sigsValid :: Bool
    sigsValid = all (\(v,_,_) -> v) sigs
    invalidSigs = filter (\(v,_,_) -> not v) sigs
  in if hash' /= _cuHash
     then ProcessedConfigFailure $! "Hash Mismatch in ConfigUpdate: ours=" ++ show hash' ++ " theirs=" ++ show _cuHash
     else if sigsValid
          then case eitherDecodeStrict' _cuCmd of
                 Left !err -> ProcessedConfigFailure err
                 Right !v -> ProcessedConfigSuccess v (Map.keysSet _cuSigs)
          else ProcessedConfigFailure $! "Sig(s) Invalid: " ++ show invalidSigs
{-# INLINE processConfigUpdate #-}

data ProcessedConfigUpdate =
  ProcessedConfigFailure !String |
  ProcessedConfigSuccess { _pcsRes :: !ConfigUpdateCommand
                         , _pcsKeysUsed :: !(Set PublicKey)}
  deriving (Show, Eq, Ord, Generic)

data ConfigUpdateResult =
  ConfigUpdateFailure !String
  | ConfigUpdateSuccess
  deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON, Serialize)

data KeyPair = KeyPair
  { _kpPublicKey :: PublicKey
  , _kpPrivateKey :: PrivateKey
  } deriving (Show, Eq, Generic)
instance ToJSON KeyPair where
  toJSON = genericToJSON (confUpdateJsonOptions 3)
instance FromJSON KeyPair where
  parseJSON = genericParseJSON (confUpdateJsonOptions 3)

getNewKeyPair :: FilePath -> IO KeyPair
getNewKeyPair fp = do
  kp <- Y.decodeFileEither fp
  case kp of
    Left err -> error $ "Unable to find and decode new keypair at location: " ++ fp ++ "\n## Error ##\n" ++ show err
    Right kp' -> return kp'

execConfigUpdateCmd :: Config -> ConfigUpdateCommand -> IO (Either String Config)
execConfigUpdateCmd conf@Config{..} cuc = do
  case cuc of
    AddNode{..}
      | _nodeId == _cucNodeId || Set.member _cucNodeId _otherNodes ->
          return $ Left $ "Unable to add node, already present"
      | _cucNodeClass == Passive ->
          return $ Left $ "Passive mode is not currently supported"
      | otherwise ->
          return $ Right $! conf
          { _otherNodes = Set.insert _cucNodeId _otherNodes
          , _publicKeys = Map.insert (_alias _cucNodeId) _cucPublicKey _publicKeys }
    RemoveNode{..}
      | _nodeId == _cucNodeId || Set.member _cucNodeId _otherNodes ->
          return $ Right $! conf
            { _otherNodes = Set.delete _cucNodeId _otherNodes
            , _publicKeys = Map.delete (_alias _cucNodeId) _publicKeys }
      | otherwise ->
          return $ Left $ "Unable to delete node, not found"
    NodeToPassive{..} -> return $ Left $ "Passive mode is not currently supported"
    NodeToActive{..} -> return $ Left $ "Active mode is the only mode currently supported"
    UpdateNodeKey{..}
      | _alias _nodeId == _cucAlias -> do
          KeyPair{..} <- getNewKeyPair _cucKeyPairPath
          return $ Right $! conf
            { _myPublicKey = _kpPublicKey
            , _myPrivateKey = _kpPrivateKey }
      | Map.member _cucAlias _publicKeys -> return $ Right $! conf
          { _publicKeys = Map.insert _cucAlias _cucPublicKey _publicKeys }
      | otherwise -> return $ Left $ "Unable to delete node, not found"
    AddAdminKey{..}
      | Map.member _cucAlias _adminKeys ->
          return $ Left $ "admin alias already present: " ++ show _cucAlias
      | otherwise -> return $ Right $! conf
          { _adminKeys = Map.insert _cucAlias _cucPublicKey _adminKeys }
    UpdateAdminKey{..}
      | Map.member _cucAlias _adminKeys -> return $ Right $! conf
          { _adminKeys = Map.insert _cucAlias _cucPublicKey _adminKeys }
      | otherwise ->
          return $ Left $ "Unable to find admin alias: " ++ show _cucAlias
    RemoveAdminKey{..}
      | Map.member _cucAlias _adminKeys -> return $ Right $! conf
          { _adminKeys = Map.delete _cucAlias _adminKeys }
      | otherwise ->
          return $ Left $ "Unable to find admin alias: " ++ show _cucAlias
    RotateLeader{..} ->
      return $ Left $ "Admin triggered leader rotation is not currently supported"

data GlobalConfig = GlobalConfig
  { _gcVersion :: !ConfigVersion
  , _gcConfig :: !Config
  } deriving (Show, Generic)
makeLenses ''GlobalConfig

type GlobalConfigTMVar = TMVar GlobalConfig

initGlobalConfigTMVar :: Config -> IO GlobalConfigTMVar
initGlobalConfigTMVar c = newTMVarIO $ GlobalConfig initialConfigVersion c

mutateConfig :: GlobalConfigTMVar -> ProcessedConfigUpdate -> IO ConfigUpdateResult
mutateConfig _ (ProcessedConfigFailure err) = return $ ConfigUpdateFailure err
mutateConfig gc (ProcessedConfigSuccess cuc keysUsed) = do
  origGc@GlobalConfig{..} <- atomically $ takeTMVar gc
  missingKeys <- return $ getMissingKeys _gcConfig keysUsed
  if null missingKeys
  then do
    res <- execConfigUpdateCmd _gcConfig cuc
    case res of
      Left err -> return $! ConfigUpdateFailure $ "Failure: " ++ err
      Right conf' -> atomically $ do
        putTMVar gc $ GlobalConfig { _gcVersion = ConfigVersion $ configVersion _gcVersion + 1
                                  , _gcConfig = conf' }
        return ConfigUpdateSuccess

  else do
    atomically $ putTMVar gc origGc
    return $ ConfigUpdateFailure $ "Admin signatures missing from: " ++ show missingKeys

getMissingKeys :: Config -> Set PublicKey -> [Alias]
getMissingKeys Config{..} keysUsed = fst <$> (filter (\(_,k) -> not $ Set.member k keysUsed) $ Map.toList _adminKeys)

getConfigWhenNew :: ConfigVersion -> GlobalConfigTMVar -> STM GlobalConfig
getConfigWhenNew cv gcm = do
  gc@GlobalConfig{..} <- readTMVar gcm
  if _gcVersion > cv
  then return gc
  else retry

data ConfigUpdater = ConfigUpdater
  { _cuPrintFn :: !(String -> IO ())
  , _cuThreadName :: !String
  , _cuAction :: (Config -> IO())}

runConfigUpdater :: ConfigUpdater -> GlobalConfigTMVar -> IO ()
runConfigUpdater ConfigUpdater{..} gcm = go initialConfigVersion
  where
    go cv = do
      GlobalConfig{..} <- atomically $ getConfigWhenNew cv gcm
      _cuAction _gcConfig
      _cuPrintFn $ "[" ++ _cuThreadName ++ "] config update fired for version: " ++ show _gcVersion
      go _gcVersion

readCurrentConfig :: GlobalConfigTMVar -> IO Config
readCurrentConfig gcm = _gcConfig <$> (atomically $ readTMVar gcm)
