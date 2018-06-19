{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Config.TMVar
  ( Config(..), clusterMembers, nodeId, publicKeys, adminKeys, myPrivateKey, myPublicKey
  , electionTimeoutRange, heartbeatTimeout, enableDebug, apiPort, entity, logDir, enablePersistence
  , pactPersist, aeBatchSize, preProcThreadCount, preProcUsePar, inMemTxCache, hostStaticDir
  , nodeClass, logRules
  , checkVoteQuorum
  , initGlobalConfigTMVar
  , GlobalConfig(..), gcVersion, gcConfig
  , GlobalConfigTMVar
  , readCurrentConfig
  ) where

import Control.Concurrent.STM
import Control.Lens (makeLenses)
import Data.Aeson
import Data.Map (Map)
import Data.Set (Set)
import GHC.Generics

import qualified Kadena.Config.ClusterMembership as CM
import Kadena.Config.Pact.Types
import Kadena.Types.Base
import Kadena.Types.Entity
import Pact.Types.Logger hiding (logRules)
import Pact.Types.Util

data Config = Config
  { _clusterMembers       :: !CM.ClusterMembership
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
makeLenses ''Config
instance ToJSON Config where
  toJSON = lensyToJSON 1
instance FromJSON Config where
  parseJSON = lensyParseJSON 1


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
