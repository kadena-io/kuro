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
import Data.Serialize (Serialize)
import Data.Set (Set)
import Data.Thyme.Time.Core ()
import GHC.Generics

import Kadena.Types.Base
import Kadena.Config.TMVar

data ConfigUpdater = ConfigUpdater
  { _cuPrintFn :: !(String -> IO ())
  , _cuThreadName :: !String
  , _cuAction :: (Config -> IO()) }

data DiffNodes = DiffNodes
  { nodesToAdd :: !(Set NodeId)
  , nodesToRemove :: !(Set NodeId)
  } deriving (Show,Eq,Ord,Generic)
