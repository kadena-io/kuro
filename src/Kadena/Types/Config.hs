{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}

module Kadena.Types.Config
  ( otherNodes, changeToNodes, nodeId, electionTimeoutRange, heartbeatTimeout
  , enableDebug, publicKeys, myPrivateKey, pactPersist
  , myPublicKey, apiPort, hostStaticDir
  , logDir, entity, nodeClass, adminKeys
  , aeBatchSize, preProcThreadCount, preProcUsePar
  , inMemTxCache, enablePersistence, logRules
  , confUpdateJsonOptions, getMissingKeys 
  , ksCluster, confToKeySet
  , initGlobalConfigTMVar, getConfigWhenNew
  , getNewKeyPair, gcVersion, gcConfig
  , readCurrentConfig
  , Config(..)
  , ConfigUpdate(..)   
  , ConfigUpdateCommand(..)
  , ConfigUpdater(..)
  , ConfigUpdateResult(..)
  , DiffNodes(..)
  , GlobalConfig(..)
  , GlobalConfigTMVar
  , KeyPair(..)
  , KeySet(..) 
  , NodesToDiff(..)
  , PactPersistBackend(..)
  , PactPersistConfig(..)
  , PPBType(..)
  , ProcessedConfigUpdate(..)
  ) where

import Control.Concurrent.STM
import Control.Lens (makeLenses)
import Control.Monad

import qualified Data.Text as Text
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Serialize
import Data.Set (Set)
import qualified Data.Set as Set
import Text.Read (readMaybe)

import Data.Aeson
import Data.Aeson.Types
import Data.Thyme.Clock
import Data.Thyme.Time.Core ()
import GHC.Generics hiding (from)
import Data.Default
import qualified Data.Yaml as Y

import Pact.Types.Util
import Pact.Types.Logger (LogRules)
import Pact.Types.SQLite (SQLiteConfig)
import Pact.Persist.MSSQL (MSSQLConfig(..))

import Kadena.Types.Base
import Kadena.Types.Entity (EntityConfig)

data PactPersistBackend =
  PPBInMemory |
  PPBSQLite { _ppbSqliteConfig :: SQLiteConfig } |
  PPBMSSQL { _ppbMssqlConfig :: Maybe MSSQLConfig,
             _ppbMssqlConnStr :: String }
  deriving (Show,Generic)

data PactPersistConfig = PactPersistConfig {
  _ppcWriteBehind :: Bool,
  _ppcBackend :: PactPersistBackend
  } deriving (Show,Generic)
instance ToJSON PactPersistConfig where toJSON = lensyToJSON 4
instance FromJSON PactPersistConfig where parseJSON = lensyParseJSON 4

data Config = Config
  { _otherNodes           :: !(Set NodeId)
  , _changeToNodes        :: !(Set NodeId) -- new set of nodes due to config change request
  , _nodeId               :: !NodeId
  , _publicKeys           :: !(Map Alias PublicKey)
  , _adminKeys            :: !(Map Alias PublicKey)
  , _myPrivateKey         :: !PrivateKey
  , _myPublicKey          :: !PublicKey
  , _electionTimeoutRange :: !(Int,Int)
  , _heartbeatTimeout     :: !Int
  , _enableDebug          :: !Bool
  , _apiPort              :: !Int
  , _entity               :: !EntityConfig
  , _logDir               :: !FilePath
  , _enablePersistence    :: !Bool
  , _pactPersist          :: !PactPersistConfig
  , _aeBatchSize          :: !Int
  , _preProcThreadCount   :: !Int
  , _preProcUsePar        :: !Bool
  , _inMemTxCache         :: !Int -- how many committed transactions should we keep in memory (with the rest on disk)
  , _hostStaticDir        :: !Bool
  , _nodeClass            :: !NodeClass
  , _logRules             :: !LogRules
  }
  deriving (Show, Generic)

data PPBType = SQLITE|MSSQL|INMEM deriving (Eq,Show,Read,Generic,FromJSON,ToJSON)

instance FromJSON PactPersistBackend where
  parseJSON = withObject "PactPersistBackend" $ \o -> do
    ty <- o .: "type"
    case ty of
      SQLITE -> PPBSQLite <$> o .: "config"
      MSSQL -> PPBMSSQL <$> o .:? "config" <*> o .: "connStr"
      INMEM -> return PPBInMemory
instance ToJSON PactPersistBackend where
  toJSON p = object $ case p of
    PPBInMemory -> [ "type" .= INMEM ]
    PPBSQLite {..} -> [ "type" .= SQLITE, "config" .= _ppbSqliteConfig ]
    PPBMSSQL {..} -> [ "type" .= MSSQL, "config" .= _ppbMssqlConfig, "connStr" .= _ppbMssqlConnStr ]

makeLenses ''Config

data ProcessedConfigUpdate =
  ProcessedConfigFailure !String |
  ProcessedConfigSuccess { _pcsRes :: !ConfigUpdateCommand
                         , _pcsKeysUsed :: !(Set PublicKey)}
  deriving (Show, Eq, Ord, Generic)

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

data ConfigUpdate a = ConfigUpdate
  { _cuHash :: !Hash
  , _cuSigs :: !(Map PublicKey Signature)
  , _cuCmd :: !a
  } deriving (Show, Eq, Ord, Generic, Serialize)
-- makeLenses ''ConfigUpdate

confUpdateJsonOptions :: Int -> Options
confUpdateJsonOptions n = defaultOptions
  { fieldLabelModifier = lensyConstructorToNiceJson n
  , sumEncoding = ObjectWithSingleField }

instance ToJSON ConfigUpdateCommand where
  toJSON = genericToJSON (confUpdateJsonOptions 4)
instance FromJSON ConfigUpdateCommand where
  parseJSON = genericParseJSON (confUpdateJsonOptions 4)

instance (ToJSON a) => ToJSON (ConfigUpdate a) where
  toJSON = lensyToJSON 3
instance (FromJSON a) => FromJSON (ConfigUpdate a) where
  parseJSON = lensyParseJSON 3

data ConfigUpdater = ConfigUpdater
  { _cuPrintFn :: !(String -> IO ())
  , _cuThreadName :: !String
  , _cuAction :: (Config -> IO())}

data ConfigUpdateResult =
  ConfigUpdateFailure !String
  | ConfigUpdateSuccess
  deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON, Serialize)

data NodesToDiff = NodesToDiff
  { prevNodes :: !(Set NodeId)
  , currentNodes :: !(Set NodeId)
  } deriving (Show,Eq,Ord,Generic)

data DiffNodes = DiffNodes
  { nodesToAdd :: !(Set NodeId)
  , nodesToRemove :: !(Set NodeId)
  } deriving (Show,Eq,Ord,Generic)

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

data GlobalConfig = GlobalConfig
  { _gcVersion :: !ConfigVersion
  , _gcConfig :: !Config
  } deriving (Show, Generic)
makeLenses ''GlobalConfig

type GlobalConfigTMVar = TMVar GlobalConfig

initGlobalConfigTMVar :: Config -> IO GlobalConfigTMVar
initGlobalConfigTMVar c = newTMVarIO $ GlobalConfig initialConfigVersion c

getMissingKeys :: Config -> Set PublicKey -> [Alias]
getMissingKeys Config{..} keysUsed = fst <$> (filter (\(_,k) -> not $ Set.member k keysUsed) $ Map.toList _adminKeys)

getConfigWhenNew :: ConfigVersion -> GlobalConfigTMVar -> STM GlobalConfig
getConfigWhenNew cv gcm = do
  gc@GlobalConfig{..} <- readTMVar gcm
  if _gcVersion > cv
  then return gc
  else retry

readCurrentConfig :: GlobalConfigTMVar -> IO Config
readCurrentConfig gcm = _gcConfig <$> (atomically $ readTMVar gcm)

