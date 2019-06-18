{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UndecidableInstances #-}

module Kadena.Types.Entity
  ( EntityKeyPair(..)
  , toKeyPair, genKeyPair
  , EntityPublicKey(..)
  , EntityLocal(..),elName,elStatic,elEphemeral,ecSigner
  , EntityRemote(..),erName,erStatic
  , EntityConfig(..),ecLocal,ecRemotes,ecSending
  , EntityConfig'(..)
  , EntityName
  , Signer(..)
  , Signer'(..)
  ) where

import Control.Lens (makeLenses)
import Control.Monad (unless)
import Crypto.Noise.DH (DH(..))
import qualified Crypto.Noise.DH as D_H
import Crypto.Noise.DH.Curve25519 (Curve25519)
import Data.Aeson (ToJSON(..),FromJSON(..),object,(.=),withObject,(.:))
import Data.ByteArray (convert)
import Data.Monoid ((<>))
import GHC.Generics (Generic)

import Pact.Types.Runtime (EntityName)
import Pact.Types.Util (AsString(..),lensyToJSON,lensyParseJSON,toB16JSON,parseB16JSON,toB16Text)
import qualified Pact.Types.Crypto as P
import Pact.Types.Scheme as P


data EntityKeyPair c = EntityKeyPair
  { _ekSecret :: D_H.SecretKey c
  , _ekPublic :: D_H.PublicKey c
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

toKeyPair :: DH c => EntityKeyPair c -> D_H.KeyPair c
toKeyPair EntityKeyPair{..} = (_ekSecret,_ekPublic)

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


newtype EntityPublicKey s = EntityPublicKey { _epPublic :: D_H.PublicKey s }

instance DH s => ToJSON (EntityPublicKey s) where
  toJSON (EntityPublicKey k) = toB16JSON . convert $ dhPubToBytes k

instance DH s => FromJSON (EntityPublicKey s) where
  parseJSON v = parseB16JSON v >>= \b -> case dhBytesToPub (convert b) of
    Nothing -> fail $ "Bad public key value: " ++ show v
    Just k -> return $ EntityPublicKey k

newtype EntityPrivateKey s = EntityPrivateKey { _epPrivate :: D_H.SecretKey s }

data EntityRemote = EntityRemote
  { _erName :: !EntityName
  , _erStatic :: !(EntityPublicKey Curve25519)
  } deriving (Generic)
makeLenses ''EntityRemote

instance Show EntityRemote where
  show EntityRemote{..} = show ("EntityRemote:" <> asString _erName)

instance ToJSON EntityRemote where toJSON = lensyToJSON 3
instance FromJSON EntityRemote where parseJSON = lensyParseJSON 3

newtype Signer' s = Signer' { signer :: (P.PPKScheme, P.PrivateKey s, P.PublicKey s) }
  deriving (Generic)

type Signer = Signer' (P.SPPKScheme 'P.ED25519)
instance Show Signer

instance (P.Scheme s, ToJSON (P.PrivateKey s), ToJSON (P.PublicKey s)) => ToJSON (Signer' s) where
  toJSON (Signer' (_, priv, pub)) = object [
    "private" .= priv
    , "public" .= pub
    ]
instance (P.Scheme s, FromJSON (P.PrivateKey s), FromJSON (P.PublicKey s)) => FromJSON (Signer' s) where
  parseJSON = withObject "Signer" $ \o ->
    Signer' <$>
      ((,,) <$> pure P.ED25519 <*> o .: "private" <*> o .: "public")

data EntityConfig' s = EntityConfig'
  { _ecLocal :: EntityLocal
  , _ecRemotes :: [EntityRemote]
  , _ecSending :: Bool
  , _ecSigner :: Signer' s
  } deriving (Generic)

instance (P.Scheme s, Show (Signer' s)) => Show (EntityConfig' s)
instance (P.Scheme s, ToJSON (Signer' s)) => ToJSON (EntityConfig' s) where toJSON = lensyToJSON 3
instance (P.Scheme s, FromJSON (Signer' s)) => FromJSON (EntityConfig' s) where parseJSON = lensyParseJSON 3
makeLenses ''EntityConfig'

type EntityConfig = EntityConfig' (P.SPPKScheme 'P.ED25519)

genKeyPair :: DH c => IO (EntityKeyPair c)
genKeyPair = uncurry EntityKeyPair <$> dhGenKey
