{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.KeySet
 ( KeySet(..), ksCluster
 ) where

import Control.Lens (makeLenses)
import Data.Default
import Data.Map (Map)
import qualified Data.Map as Map

import qualified Pact.Types.Crypto as P (PublicKey)

import Kadena.Types.Base (Alias)

data KeySet s = KeySet
  { _ksCluster :: !(Map Alias (P.PublicKey s))
  }
makeLenses ''KeySet
instance Default (KeySet a) where
  def = KeySet Map.empty
