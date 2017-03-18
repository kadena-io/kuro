{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Config
  ( Config(..), otherNodes, nodeId, electionTimeoutRange, heartbeatTimeout
  , enableDebug, publicKeys, clientPublicKeys, myPrivateKey, clientTimeoutLimit
  , myPublicKey, batchTimeDelta, apiPort
  , logSqliteDir, entity, dbFile
  , aeBatchSize, preProcThreadCount, preProcUsePar
  , KeySet(..), ksCluster
  , EntityInfo(..),entName
  ) where

import Control.Lens hiding (Index, (|>))
import Data.Map (Map,empty)
import Data.Set (Set)
import Text.Read (readMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Thyme.Clock
import Data.Thyme.Time.Core ()
import Data.Aeson
import Data.Aeson.Types
import GHC.Generics hiding (from)
import Control.Monad
import Data.Default

import Kadena.Types.Base

data EntityInfo = EntityInfo {
      _entName :: Text
} deriving (Eq,Show,Generic)
$(makeLenses ''EntityInfo)
instance ToJSON EntityInfo where
  toJSON = genericToJSON defaultOptions { fieldLabelModifier = drop 4 }
instance FromJSON EntityInfo where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 4 }


data Config = Config
  { _otherNodes           :: !(Set NodeId)
  , _nodeId               :: !NodeId
  , _publicKeys           :: !(Map Alias PublicKey)
  , _clientPublicKeys     :: !(Map Alias PublicKey)
  , _myPrivateKey         :: !PrivateKey
  , _myPublicKey          :: !PublicKey
  , _electionTimeoutRange :: !(Int,Int)
  , _heartbeatTimeout     :: !Int
  , _batchTimeDelta       :: !NominalDiffTime
  , _enableDebug          :: !Bool
  , _clientTimeoutLimit   :: !Int
  , _apiPort              :: !Int
  , _logSqliteDir         :: !(Maybe FilePath)
  , _entity               :: EntityInfo
  , _dbFile               :: !(Maybe FilePath)
  , _aeBatchSize          :: !Int
  , _preProcThreadCount   :: !Int
  , _preProcUsePar        :: !Bool
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
  toJSON = genericToJSON defaultOptions { fieldLabelModifier = drop 1 }
instance FromJSON Config where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 1 }

data KeySet = KeySet
  { _ksCluster :: !(Map Alias PublicKey)
  } deriving (Show)
makeLenses ''KeySet
instance Default KeySet where def = KeySet empty
