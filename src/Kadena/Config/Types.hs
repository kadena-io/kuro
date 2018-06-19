{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE FlexibleInstances #-}

module Kadena.Config.Types
  ( ConfigUpdater(..)
  , DiffNodes(..)
  , GlobalConfigTMVar
  , KeyPair(..)
  ) where

import Data.Aeson (ToJSON, FromJSON)
import qualified Data.Aeson as A
import Data.Serialize (Serialize)
import Data.Set (Set)
import Data.Thyme.Time.Core ()
import GHC.Generics

import Kadena.Types.Base
import Kadena.Config.TMVar

import Pact.Types.Util

data ConfigUpdater = ConfigUpdater
  { _cuPrintFn :: !(String -> IO ())
  , _cuThreadName :: !String
  , _cuAction :: (Config -> IO()) }

data DiffNodes = DiffNodes
  { nodesToAdd :: !(Set NodeId)
  , nodesToRemove :: !(Set NodeId)
  } deriving (Show,Eq,Ord,Generic)

data KeyPair = KeyPair
  { _kpPublicKey :: PublicKey
  , _kpPrivateKey :: PrivateKey
  } deriving (Show, Eq, Generic)
instance ToJSON KeyPair where
  toJSON = lensyToJSON 3
instance FromJSON KeyPair where
  parseJSON = lensyParseJSON 3

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









