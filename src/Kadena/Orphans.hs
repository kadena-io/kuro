{-# OPTIONS_GHC -fno-warn-orphans #-}

module Kadena.Orphans () where

import Data.Aeson
import qualified Crypto.Ed25519.Pure as Ed25519

import qualified Pact.Types.Util as P

----------------------------------------------------------------------------------------------------
instance ToJSON Ed25519.PublicKey where
  toJSON = P.toB16JSON . Ed25519.exportPublic
instance FromJSON Ed25519.PublicKey where
  parseJSON = withText "Ed25519.PublicKey" P.parseText
  {-# INLINE parseJSON #-}
instance P.ParseText Ed25519.PublicKey where
  parseText s = do
    s' <- P.parseB16Text s
    P.failMaybe ("Public key import failed: " ++ show s) $ Ed25519.importPublic s'
  {-# INLINE parseText #-}

----------------------------------------------------------------------------------------------------
instance ToJSON Ed25519.PrivateKey where
  toJSON = P.toB16JSON . Ed25519.exportPrivate
instance FromJSON Ed25519.PrivateKey where
  parseJSON = withText "Ed25519.PrivateKey" P.parseText
  {-# INLINE parseJSON #-}
instance P.ParseText Ed25519.PrivateKey where
  parseText s = do
    s' <- P.parseB16Text s
    P.failMaybe ("Private key import failed: " ++ show s) $ Ed25519.importPrivate s'
  {-# INLINE parseText #-}
