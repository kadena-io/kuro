{-# LANGUAGE TemplateHaskell #-}

module Kadena.Crypto
  ( KeySet(..), ksCluster
  , sign
  , valid ) where

import Control.Lens (makeLenses)
import qualified Crypto.Ed25519.Pure as Ed25519
import Data.Default
import Data.Map (Map)
import qualified Data.Map as Map

import qualified Pact.Types.Hash as P

import Kadena.Types.Base (Alias)

----------------------------------------------------------------------------------------------------
data KeySet = KeySet
  { _ksCluster :: !(Map Alias Ed25519.PublicKey)
  }
makeLenses ''KeySet

instance Default KeySet where
  def = KeySet Map.empty

----------------------------------------------------------------------------------------------------
valid :: P.Hash -> Ed25519.PublicKey -> Ed25519.Signature -> Bool
valid (P.Hash msg) pub sig = Ed25519.valid msg pub sig

----------------------------------------------------------------------------------------------------
sign :: P.Hash -> Ed25519.PrivateKey -> Ed25519.PublicKey -> Ed25519.Signature
sign (P.Hash msg) priv pub = Ed25519.sign msg priv pub
