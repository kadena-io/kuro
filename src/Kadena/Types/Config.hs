{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleInstances #-}

module Kadena.Types.Config
  ( Config(..), otherNodes, changeToNodes, nodeId, publicKeys, adminKeys, myPrivateKey, myPublicKey
  , electionTimeoutRange, heartbeatTimeout, enableDebug, apiPort, entity, logDir, enablePersistence
  , pactPersist, aeBatchSize, preProcThreadCount, preProcUsePar, inMemTxCache, hostStaticDir
  , nodeClass, logRules
  , ConfigUpdater (..)
  , DiffNodes(..)
  , GlobalConfig(..),  gcVersion, gcConfig
  , GlobalConfigTMVar
  , KeyPair(..)
  , PactPersistBackend(..)
  , PactPersistConfig(..)
  , PPBType(..)
  , confToKeySet
  , getConfigWhenNew
  , getNewKeyPair
  , initGlobalConfigTMVar
  , readCurrentConfig
  ) where

import Control.Concurrent.STM
import Control.Lens (makeLenses)
import Data.Aeson (ToJSON, FromJSON, (.:), (.:?), (.=))
import qualified Data.Aeson as A
import Data.Map (Map)
import Data.Serialize (Serialize)
import Data.Set (Set)
import Data.Thyme.Time.Core ()
import qualified Data.Yaml as Y
import GHC.Generics

import Pact.Persist.MSSQL (MSSQLConfig(..))
import Pact.Types.Logger (LogRules)
import Pact.Types.Util
import Pact.Types.SQLite (SQLiteConfig)

import Kadena.Types.Base
import Kadena.Types.Entity (EntityConfig)
import Kadena.Types.KeySet

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
  parseJSON = A.withObject "PactPersistBackend" $ \o -> do
    ty <- o .: "type"
    case ty of
      SQLITE -> PPBSQLite <$> o .: "config"
      MSSQL -> PPBMSSQL <$> o .:? "config" <*> o .: "connStr"
      INMEM -> return PPBInMemory
instance ToJSON PactPersistBackend where
  toJSON p = A.object $ case p of
    PPBInMemory -> [ "type" .= INMEM ]
    PPBSQLite {..} -> [ "type" .= SQLITE, "config" .= _ppbSqliteConfig ]
    PPBMSSQL {..} -> [ "type" .= MSSQL, "config" .= _ppbMssqlConfig, "connStr" .= _ppbMssqlConnStr ]

makeLenses ''Config
instance ToJSON Config where
  toJSON = lensyToJSON 1
instance FromJSON Config where
  parseJSON = lensyParseJSON 1

data ConfigUpdater = ConfigUpdater
  { _cuPrintFn :: !(String -> IO ())
  , _cuThreadName :: !String
  , _cuAction :: (Config -> IO()) }

data DiffNodes = DiffNodes
  { nodesToAdd :: !(Set NodeId)
  , nodesToRemove :: !(Set NodeId)
  } deriving (Show,Eq,Ord,Generic)

confToKeySet :: Config -> KeySet
confToKeySet Config{..} = KeySet
  { _ksCluster = _publicKeys}

data KeyPair = KeyPair
  { _kpPublicKey :: PublicKey
  , _kpPrivateKey :: PrivateKey
  } deriving (Show, Eq, Generic)
instance ToJSON KeyPair where
  toJSON = lensyToJSON 3
instance FromJSON KeyPair where
  parseJSON = lensyParseJSON 3

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

getConfigWhenNew :: ConfigVersion -> GlobalConfigTMVar -> STM GlobalConfig
getConfigWhenNew cv gcm = do
  gc@GlobalConfig{..} <- readTMVar gcm
  if _gcVersion > cv
  then return gc
  else retry

readCurrentConfig :: GlobalConfigTMVar -> IO Config
readCurrentConfig gcm = _gcConfig <$> (atomically $ readTMVar gcm)

-- | Not implemented
data NodeUpdateCommand =
  NodeToPassive
    { _nucNodeId :: !NodeId } |
  NodeToActive
    { _nucNodeId :: !NodeId } |
  UpdateNodeKey
    { _nucAlias :: !Alias
    , _nucPublicKey :: !PublicKey
    , _nucKeyPairPath :: !FilePath }
  deriving (Show, Eq, Ord, Generic, Serialize)

-- | Not implemented
data AdminUpdateCommand =
  AddAdminKey
    { _aucAlias :: !Alias
    , _cucPublicKey :: !PublicKey } |
  UpdateAdminKey
    { _aucAlias :: !Alias
    , _cucPublicKey :: !PublicKey } |
  RemoveAdminKey
    { _aucAlias :: !Alias }
  deriving (Show, Eq, Ord, Generic, Serialize)

  -- | Not implemented
data AdminCommand =
  RotateLeader
    { _cucTerm :: !Term }
  deriving (Show, Eq, Ord, Generic, Serialize)
