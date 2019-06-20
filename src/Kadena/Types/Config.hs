{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE FlexibleInstances #-}

module Kadena.Types.Config
  ( ConfigUpdater(..)
  , DiffNodes(..)
  , GlobalConfigTMVar
  ) where

import qualified Crypto.Ed25519.Pure as Ed25519
import Data.Aeson (ToJSON, FromJSON)
import qualified Data.Aeson as A
import Data.Serialize (Serialize)
import Data.Set (Set)
import Data.Thyme.Time.Core ()
import GHC.Generics

import Pact.Types.Util

import Kadena.Types.Base
import Kadena.Config.TMVar
import Kadena.Types.Message.Signed

data ConfigUpdater = ConfigUpdater
  { _cuPrintFn :: !(String -> IO ())
  , _cuThreadName :: !String
  , _cuAction :: (Config -> IO()) }

data DiffNodes = DiffNodes
  { nodesToAdd :: !(Set NodeId)
  , nodesToRemove :: !(Set NodeId)
  } deriving (Show,Eq,Ord,Generic)

-- Not implemented
data AdminUpdateCommand =
    AddAdminKey
      { _aucAlias :: !Alias
      , _cucPublicKey :: !Ed25519.PublicKey } |
    UpdateAdminKey
      { _aucAlias :: !Alias
      , _cucPublicKey :: !Ed25519.PublicKey } |
    RemoveAdminKey
      { _aucAlias :: !Alias }
    deriving (Show, Eq, Ord, Generic, Serialize)

-- Not implemented
data AdminCommand =
    RotateLeader
      { _cucTerm :: !Term }
    deriving (Show, Eq, Ord, Generic, Serialize)
