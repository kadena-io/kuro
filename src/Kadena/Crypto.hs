{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Crypto
  ( KeyPair(..), kpPublicKey, kpPrivateKey
  , KeySet(..), ksCluster
  , sign
  , valid ) where

import Control.DeepSeq
import Control.Lens (makeLenses)
import qualified Crypto.Ed25519.Pure as Ed25519
import Data.Aeson
import Data.Default
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import Data.Text (Text)
import GHC.Generics

import qualified Pact.Types.Hash as P
import Pact.Types.Util (ParseText(..), parseB16Text, toB16JSON)

import Kadena.Types.Base (Alias, failMaybe)

----------------------------------------------------------------------------------------------------
data KeyPair = KeyPair
  { _kpPublicKey :: Ed25519.PublicKey
  , _kpPrivateKey :: Ed25519.PrivateKey
  } deriving (Eq, Show, Generic)
makeLenses ''KeyPair

instance ToJSON KeyPair where
  toJSON (KeyPair p s) =
    object [ "publicKey" .= toB16JSON (Ed25519.exportPublic p)
           , "privateKey" .= toB16JSON (Ed25519.exportPrivate s) ]

instance FromJSON KeyPair where
    parseJSON = withObject "KeyPair" $ \v -> KeyPair
        <$> v .: "publicKey"
        <*> v .: "privateKey"


-- TODO: move to Orphans module
----------------------------------------------------------------------------------------------------
instance ToJSON Ed25519.PublicKey where
  toJSON = toB16JSON . Ed25519.exportPublic
instance FromJSON Ed25519.PublicKey where
  parseJSON = withText "Ed25519.PublicKey" parseText
  {-# INLINE parseJSON #-}
instance ParseText Ed25519.PublicKey where
  parseText s = do
    s' <- parseB16Text s
    failMaybe ("Public key import failed: " ++ show s) $ Ed25519.importPublic s'
  {-# INLINE parseText #-}
-- instance Serialize Ed25519.PublicKey where
--   put s = S.putByteString (Ed25519.exportPublic s)
--   get = maybe (fail "Invalid PubKey") return =<< (Ed25519.importPublic <$> S.getByteString 32)
instance Generic Ed25519.PublicKey
----------------------------------------------------------------------------------------------------
instance ToJSON Ed25519.PrivateKey where
  toJSON = toB16JSON . Ed25519.exportPrivate
instance FromJSON Ed25519.PrivateKey where
  parseJSON = withText "Ed25519.PrivateKey" parseText
  {-# INLINE parseJSON #-}
instance ParseText Ed25519.PrivateKey where
  parseText s = do
    s' <- parseB16Text s
    failMaybe ("Private key import failed: " ++ show s) $ Ed25519.importPrivate s'
  {-# INLINE parseText #-}
-- instance Serialize Ed25519.PrivateKey where
--   put s = S.putByteString (Ed25519.exportPrivate s)
--   get = maybe (fail "Invalid PubKey") return =<< (Ed25519.importPrivate <$> S.getByteString 32)
instance Generic Ed25519.PrivateKey

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
