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
  , EntitySecretKey(..)
  , EntityLocal(..),elName,elStatic,elEphemeral,ecSigner
  , EntityRemote(..),erName,erStatic
  , EntityConfig(..),ecLocal,ecRemotes,ecSending
  , EntityName
  ) where

import Control.Lens (makeLenses)
import Control.Monad (unless)
import Crypto.Noise.DH (DH(..))
import qualified Crypto.Noise.DH as Dh
import qualified Crypto.Noise.DH.Curve25519 as Dh
import Data.Aeson (ToJSON(..),FromJSON(..),object,(.=),withObject,(.:))
import Data.ByteArray (convert)
import Data.Monoid ((<>))
import GHC.Generics (Generic)

import Pact.Types.Runtime (EntityName)
import Pact.Types.Util (AsString(..),lensyToJSON,lensyParseJSON,toB16JSON,parseB16JSON,toB16Text)

----------------------------------------------------------------------------------------------------
newtype EntityPublicKey = EntityPublicKey { epPublicKey :: Dh.PublicKey Dh.Curve25519 }

instance ToJSON EntityPublicKey  where
  toJSON (EntityPublicKey k) = toB16JSON . convert $ dhPubToBytes k

instance FromJSON EntityPublicKey where
  parseJSON v = parseB16JSON v >>= \b -> case dhBytesToPub (convert b) of
    Nothing -> fail $ "Bad public key value: " ++ show v
    Just k -> return $ EntityPublicKey k

----------------------------------------------------------------------------------------------------
newtype EntitySecretKey = EntitySecretKey { esSecretKey :: Dh.SecretKey Dh.Curve25519 }

----------------------------------------------------------------------------------------------------
data EntityKeyPair = EntityKeyPair
  { ekSecret :: EntitySecretKey
  , ekPublic :: EntityPublicKey
  }

instance Show EntityKeyPair where
  show EntityKeyPair{..} = "EntityKeyPair "
    ++ show (toB16Text (convert (Dh.dhSecToBytes (esSecretKey ekSecret)))) ++
    " " ++ show (toB16Text (convert (dhPubToBytes (epPublicKey ekPublic))))

instance ToJSON EntityKeyPair where
  toJSON EntityKeyPair{..} = object [
    "secret" .= toB16JSON (convert (dhSecToBytes (esSecretKey ekSecret))),
    "public" .= toB16JSON (convert (dhPubToBytes (epPublicKey ekPublic)))
    ]

instance FromJSON EntityKeyPair where
  parseJSON = withObject "EntityKeyPair" $ \o -> do
    s <- o .: "secret" >>= parseB16JSON
    p <- o .: "public" >>= parseB16JSON
    case dhBytesToPair (convert s) of
      Nothing -> fail $ "Bad secret key value: " ++ show o
      Just (sk,pk) -> do
        unless (p == convert (dhPubToBytes pk)) $ fail $ "Bad public key value: " ++ show o
        return $ EntityKeyPair (EntitySecretKey sk) (EntityPublicKey pk)

toKeyPair :: EntityKeyPair -> Dh.KeyPair Dh.Curve25519
toKeyPair EntityKeyPair{..} = (esSecretKey ekSecret, epPublicKey ekPublic)

genKeyPair :: IO EntityKeyPair
genKeyPair = do
  (theSecretKey, thePublicKey) <- dhGenKey :: IO (Dh.SecretKey Dh.Curve25519, Dh.PublicKey Dh.Curve25519)
  return EntityKeyPair
    { ekSecret = EntitySecretKey theSecretKey
    , ekPublic = EntityPublicKey thePublicKey
    }

----------------------------------------------------------------------------------------------------
-- TODO: remove comment after all instances of Singer are replaced
-- Singer was removed as it was essentiallky the same as EntityKeyPair

----------------------------------------------------------------------------------------------------
data EntityLocal = EntityLocal
  { _elName :: !EntityName
  , _elStatic :: !EntityKeyPair
  , _elEphemeral :: !EntityKeyPair
  } deriving (Generic)
makeLenses ''EntityLocal

instance Show EntityLocal where
  show EntityLocal{..} = show ("EntityLocal:" <> asString _elName)

instance ToJSON EntityLocal where toJSON = lensyToJSON 3
instance FromJSON EntityLocal where parseJSON = lensyParseJSON 3

----------------------------------------------------------------------------------------------------
data EntityRemote = EntityRemote
  { _erName :: !EntityName
  , _erStatic :: !EntityPublicKey
  } deriving (Generic)
makeLenses ''EntityRemote

instance Show EntityRemote where
  show EntityRemote{..} = show ("EntityRemote:" <> asString _erName)

instance ToJSON EntityRemote where toJSON = lensyToJSON 3
instance FromJSON EntityRemote where parseJSON = lensyParseJSON 3

----------------------------------------------------------------------------------------------------
data EntityConfig = EntityConfig
  { _ecLocal :: EntityLocal
  , _ecRemotes :: [EntityRemote]
  , _ecSending :: Bool
  , _ecSigner :: EntityKeyPair
  } deriving (Show, Generic)

instance ToJSON EntityConfig where toJSON = lensyToJSON 3
instance FromJSON EntityConfig where parseJSON = lensyParseJSON 3
makeLenses ''EntityConfig
