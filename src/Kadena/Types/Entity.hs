{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
module Kadena.Types.Entity
  ( EntityKeyPair(..)
  , toKeyPair, genKeyPair
  , EntityPublicKey(..)
  , EntityLocal(..),elName,elStatic,elEphemeral,ecSigner
  , EntityRemote(..),erName,erStatic
  , EntityConfig(..),ecLocal,ecRemotes,ecSending
  , EntityName
  , Signer(..)
  ) where

import Control.Lens (makeLenses)
import Control.Monad (unless)
import Crypto.Noise.DH (KeyPair,DH(..))
import Crypto.Noise.DH.Curve25519 (Curve25519)
import Data.Aeson (ToJSON(..),FromJSON(..),object,(.=),withObject,(.:))
import Data.ByteArray (convert)
import Data.Monoid ((<>))
import GHC.Generics (Generic)

import Pact.Types.Runtime (EntityName)
import Pact.Types.Util (AsString(..),lensyToJSON,lensyParseJSON,toB16JSON,parseB16JSON,toB16Text)
import qualified Pact.Types.Crypto as Signing


data EntityKeyPair c = EntityKeyPair
  { _ekSecret :: SecretKey c
  , _ekPublic :: PublicKey c
  }
instance DH c => Show (EntityKeyPair c) where
  show EntityKeyPair{..} = "EntityKeyPair " ++ show (toB16Text (convert (dhSecToBytes _ekSecret))) ++
    " " ++ show (toB16Text (convert (dhPubToBytes _ekPublic)))

instance DH c => ToJSON (EntityKeyPair c) where
  toJSON EntityKeyPair{..} = object [
    "secret" .= toB16JSON (convert (dhSecToBytes _ekSecret)),
    "public" .= toB16JSON (convert (dhPubToBytes _ekPublic))
    ]
instance DH c => FromJSON (EntityKeyPair c) where
  parseJSON = withObject "EntityKeyPair" $ \o -> do
    s <- o .: "secret" >>= parseB16JSON
    p <- o .: "public" >>= parseB16JSON
    case dhBytesToPair (convert s) of
      Nothing -> fail $ "Bad secret key value: " ++ show o
      Just (sk,pk) -> do
        unless (p == convert (dhPubToBytes pk)) $ fail $ "Bad public key value: " ++ show o
        return $ EntityKeyPair sk pk

toKeyPair :: DH c => EntityKeyPair c -> KeyPair c
toKeyPair EntityKeyPair{..} = (_ekSecret,_ekPublic)

newtype EntityPublicKey c = EntityPublicKey { _epPublic :: PublicKey c }
instance DH c => ToJSON (EntityPublicKey c) where
  toJSON (EntityPublicKey k) = toB16JSON . convert $ dhPubToBytes k
instance DH c => FromJSON (EntityPublicKey c) where
  parseJSON v = parseB16JSON v >>= \b -> case dhBytesToPub (convert b) of
    Nothing -> fail $ "Bad public key value: " ++ show v
    Just k -> return $ EntityPublicKey k

data EntityLocal = EntityLocal
  { _elName :: !EntityName
  , _elStatic :: !(EntityKeyPair Curve25519)
  , _elEphemeral :: !(EntityKeyPair Curve25519)
  } deriving (Generic)
makeLenses ''EntityLocal
instance Show EntityLocal where
  show EntityLocal{..} = show ("EntityLocal:" <> asString _elName)
instance ToJSON EntityLocal where toJSON = lensyToJSON 3
instance FromJSON EntityLocal where parseJSON = lensyParseJSON 3

data EntityRemote = EntityRemote
  { _erName :: !EntityName
  , _erStatic :: !(EntityPublicKey Curve25519)
  } deriving (Generic)
makeLenses ''EntityRemote
instance Show EntityRemote where
  show EntityRemote{..} = show ("EntityRemote:" <> asString _erName)
instance ToJSON EntityRemote where toJSON = lensyToJSON 3
instance FromJSON EntityRemote where parseJSON = lensyParseJSON 3

newtype Signer = Signer { signer :: (Signing.PPKScheme, Signing.PrivateKey, Signing.PublicKey) }
  deriving (Show,Generic)
instance ToJSON Signer where
  toJSON (Signer (_sc,priv,pub)) = object [
    "private" .= priv
    , "public" .= pub
    ]
instance FromJSON Signer where
  parseJSON = withObject "Signer" $ \o ->
    Signer <$>
      ((,,) <$> pure Signing.ED25519 <*> o .: "private" <*> o .: "public")


data EntityConfig = EntityConfig
  { _ecLocal :: EntityLocal
  , _ecRemotes :: [EntityRemote]
  , _ecSending :: Bool
  , _ecSigner :: Signer
  } deriving (Show,Generic)
instance ToJSON EntityConfig where toJSON = lensyToJSON 3
instance FromJSON EntityConfig where parseJSON = lensyParseJSON 3
makeLenses ''EntityConfig

genKeyPair :: DH c => IO (EntityKeyPair c)
genKeyPair = uncurry EntityKeyPair <$> dhGenKey
