{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Crypto
  ( KeyPair(..), kpPublicKey, kpPrivateKey
  , KeySet(..), ksCluster
  , Signer(..), siPubKey, siAddress
  , sign
  , Ed25519.exportPublic, Ed25519.exportPrivate
  , valid ) where

import Control.DeepSeq
import Control.Lens (makeLenses)
import qualified Crypto.Ed25519.Pure as Ed25519
import Data.Aeson
import Data.Default
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Serialize (Serialize)
import Data.Text (Text)
import GHC.Generics

import qualified Pact.Types.Hash as P
import Pact.Types.Util (lensyParseJSON, lensyToJSON, toB16JSON)

import Kadena.Orphans ()
import Kadena.Types.Base (Alias)

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

----------------------------------------------------------------------------------------------------
data Signer = Signer
  { _siPubKey :: !Ed25519.PublicKey
  , _siAddress :: Text }
  deriving (Show, Eq, Generic)

instance Serialize Signer
instance ToJSON Signer where toJSON = lensyToJSON 3
instance FromJSON Signer where parseJSON = lensyParseJSON 3

-- Nothing really to do for Signer as NFData, but to convice the compiler:
instance NFData Signer where
  rnf (Signer _ _) = ()

makeLenses ''Signer

----------------------------------------------------------------------------------------------------
data KeySet = KeySet
  { _ksCluster :: !(Map Alias Ed25519.PublicKey)
  } deriving Eq
makeLenses ''KeySet

instance Default KeySet where
  def = KeySet Map.empty

----------------------------------------------------------------------------------------------------
valid :: P.Hash -> Ed25519.PublicKey -> Ed25519.Signature -> Bool
valid (P.Hash msg) pub sig = Ed25519.valid msg pub sig

----------------------------------------------------------------------------------------------------
sign :: P.Hash -> Ed25519.PrivateKey -> Ed25519.PublicKey -> Ed25519.Signature
sign (P.Hash msg) priv pub = Ed25519.sign msg priv pub
