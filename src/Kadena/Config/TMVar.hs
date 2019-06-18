{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module Kadena.Config.TMVar
  ( Config(..), clusterMembers, nodeId, publicKeys, adminKeys, myPrivateKey, myPublicKey
  , electionTimeoutRange, heartbeatTimeout, enableDebug, apiPort, entity, logDir, enablePersistence
  , pactPersist, aeBatchSize, preProcThreadCount, preProcUsePar, inMemTxCache, hostStaticDir
  , nodeClass, logRules, enableDiagnostics
  , checkVoteQuorum
  , initGlobalConfigTMVar
  , GlobalConfig(..), gcVersion, gcConfig
  , GlobalConfigTMVar
  , readCurrentConfig
  ) where

import Control.Concurrent.STM
import Control.Lens (makeLenses)

import qualified Crypto.Ed25519.Pure as Ed25519
import Data.Aeson
import Data.Map (Map)
import Data.Set (Set)
import GHC.Generics

import Pact.Types.Crypto
import Pact.Types.Logger hiding (logRules)
import Pact.Types.Scheme
import Pact.Types.Util

import qualified Kadena.Config.ClusterMembership as CM
import Kadena.Types.PactDB
import Kadena.Types.Base
import Kadena.Types.Entity
import  Kadena.Types.Message.Signed

data Config' s = Config'
  { _clusterMembers       :: !CM.ClusterMembership
  , _nodeId               :: !NodeId
  , _publicKeys           :: !(Map Alias (PublicKey s))
  , _adminKeys            :: !(Map Alias (PublicKey s))
  , _myPrivateKey         :: !(PrivateKey s)
  , _myPublicKey          :: !(PublicKey s)
  , _electionTimeoutRange :: !(Int,Int)
  , _heartbeatTimeout     :: !Int
  , _enableDebug          :: !Bool
  , _apiPort              :: !Int
  , _entity               :: !(EntityConfig' s)
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
  , _enableDiagnostics    :: !(Maybe Bool)
  }
  deriving (Generic)
makeLenses ''Config'

instance (Scheme s, Show (EntityConfig' s)) => Show (Config' s)

instance (Scheme s, ToJSON (PublicKey s), ToJSON (PrivateKey s), ToJSON (EntityConfig' s)) => ToJSON (Config' s) where
  toJSON = lensyToJSON 1

instance (Scheme s, FromJSON (PublicKey s), FromJSON (PrivateKey s), FromJSON (EntityConfig' s)) => FromJSON (Config' s) where
  parseJSON = lensyParseJSON 1

type Config = Config' (SPPKScheme 'ED25519)

data GlobalConfig = GlobalConfig
  { _gcVersion :: !ConfigVersion
  , _gcConfig :: !Config
  } deriving (Show, Generic)
makeLenses ''GlobalConfig

type GlobalConfigTMVar = TMVar GlobalConfig

checkVoteQuorum :: GlobalConfigTMVar -> Set NodeId -> IO Bool
checkVoteQuorum globalCfg votes = do
  theConfig <- readCurrentConfig globalCfg
  let myId = _nodeId theConfig
  let members = _clusterMembers theConfig
  return $ CM.checkQuorumIncluding members votes myId

initGlobalConfigTMVar :: Config -> IO GlobalConfigTMVar
initGlobalConfigTMVar c = newTMVarIO $ GlobalConfig initialConfigVersion c

readCurrentConfig :: GlobalConfigTMVar -> IO Config
readCurrentConfig gcm = _gcConfig <$> (atomically $ readTMVar gcm)
