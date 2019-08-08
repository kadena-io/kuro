{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.KeySet
 ( KeySet(..), ksCluster
 ) where

import Control.Lens (makeLenses)
import qualified Crypto.Ed25519.Pure as Ed (PublicKey)
import Data.Default
import Data.Map (Map)
import qualified Data.Map as Map

import Kadena.Types.Base (Alias)

data KeySet = KeySet
  { _ksCluster :: !(Map Alias Ed.PublicKey)
  } deriving (Show, Eq, Ord)
makeLenses ''KeySet
instance Default KeySet where
  def = KeySet Map.empty
