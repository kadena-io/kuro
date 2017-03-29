{-# LANGUAGE BangPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Types.Config
  ( Config(..), otherNodes, nodeId, electionTimeoutRange, heartbeatTimeout
  , enableDebug, publicKeys, myPrivateKey, enableWriteBehind
  , myPublicKey, apiPort, hostStaticDir
  , logDir, entity, nodeClass, adminKeys
  , aeBatchSize, preProcThreadCount, preProcUsePar
  , inMemTxCache, enablePersistence
  , KeySet(..), ksCluster
  , EntityInfo(..),entName
  , ConfigUpdateCommand(..)
  , ConfigUpdate(..), cuCmd, cuHash, cuSigs
  , ProcessedConfigUpdate(..), processConfigUpdate
  , ConfigUpdateResult(..)
  ) where

import Control.Lens hiding (Index, (|>))
import Control.Monad

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import Text.Read (readMaybe)

import Data.Aeson
import Data.Aeson.Types
import Data.Thyme.Clock
import Data.Thyme.Time.Core ()
import GHC.Generics hiding (from)
import Data.Serialize
import Data.Default

import Pact.Types.Util

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
  , _adminKeys            :: !(Set PublicKey)
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
  } deriving (Show)
makeLenses ''KeySet
instance Default KeySet where
  def = KeySet Map.empty

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
    { _cucNodeId :: !NodeId
    , _cucPublicKey :: !PublicKey } |
  UpdateAdminKey
    { _cucNodeId :: !NodeId
    , _cucPublicKey :: !PublicKey } |
  RotateLeader
    { _cucTerm :: !Term }
  deriving (Show, Eq, Ord, Generic, Serialize)
instance ToJSON ConfigUpdateCommand where
  toJSON = lensyToJSON 4
instance FromJSON ConfigUpdateCommand where
  parseJSON = lensyParseJSON 4

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
                 Right !v -> ProcessedConfigSuccess v
          else ProcessedConfigFailure $! "Sig(s) Invalid: " ++ show invalidSigs
{-# INLINE processConfigUpdate #-}

data ProcessedConfigUpdate =
  ProcessedConfigFailure !String |
  ProcessedConfigSuccess { _pcsRes :: !ConfigUpdateCommand }
  deriving (Show, Eq, Ord, Generic)

data ConfigUpdateResult =
  ConfigUpdateFailure !String
  | ConfigUpdateSuccess
  deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON, Serialize)
