{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}

module Kadena.Types.Base
  ( NodeId(..)
  , Term(..), startTerm
  , LogIndex(..), startIndex
  , RequestId(..)
  , ReceivedAt(..)
  -- for simplicity, re-export some core types that we need all over the place
  , parseB16JSON, toB16JSON, toB16Text, parseB16Text, failMaybe
  , PublicKey, PrivateKey, Signature(..), sign, valid, importPublic, importPrivate, exportPublic
  , Role(..)
  , EncryptionKey(..)
  , Alias(..)
  , interval
  ) where

import Control.Lens
import Control.Monad (mzero)
import Crypto.Ed25519.Pure ( PublicKey, PrivateKey, Signature(..), sign, valid
                           , importPublic, importPrivate, exportPublic, exportPrivate)

import Data.Maybe (fromMaybe)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Base16 as B16
import Data.Text (Text)
import Data.String

import Data.Map (Map)
import qualified Data.Map as Map

import Data.AffineSpace ((.-.))
import Data.Thyme.Clock

import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Aeson
import Data.Aeson.Types

import Data.Word (Word64)
import GHC.Int (Int64)
import GHC.Generics hiding (from)

import Pact.Types.Orphans ()

newtype Alias = Alias { unAlias :: BSC.ByteString }
  deriving (Eq, Ord, Generic, Serialize)
instance IsString Alias where fromString s = Alias $ BSC.pack s

instance Show Alias where
  show (Alias a) = BSC.unpack a

instance ToJSON Alias where
  toJSON = toJSON . decodeUtf8 . unAlias
instance FromJSON Alias where
  parseJSON (String s) = do
    return $ Alias $ encodeUtf8 s
  parseJSON _ = mzero

data NodeId = NodeId { _host :: !String, _port :: !Word64, _fullAddr :: !String, _alias :: !Alias}
  deriving (Eq,Ord,Generic)
instance Show NodeId where
  show nid = "NodeId: " ++ BSC.unpack (unAlias $ _alias nid)
instance Serialize NodeId
instance ToJSON NodeId where
  toJSON = genericToJSON defaultOptions { fieldLabelModifier = drop 1 }
instance FromJSON NodeId where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 1 }

newtype Term = Term Int
  deriving (Show, Read, Eq, Enum, Num, Ord, Generic, Serialize)

startTerm :: Term
startTerm = Term (-1)

newtype LogIndex = LogIndex Int
  deriving (Show, Read, Eq, Ord, Enum, Num, Real, Integral, Generic, Serialize)

startIndex :: LogIndex
startIndex = LogIndex (-1)

newtype RequestId = RequestId {_unRequestId :: String }
  deriving (Show, Eq, Ord, Generic, Serialize, IsString, ToJSON, FromJSON)


parseB16JSON :: Value -> Parser ByteString
parseB16JSON = withText "Base16" parseB16Text

parseB16Text :: Text -> Parser ByteString
parseB16Text t = case B16.decode (encodeUtf8 t) of
                 (s,leftovers) | leftovers == B.empty -> return s
                               | otherwise -> fail $ "Base16 decode failed: " ++ show t

toB16JSON :: ByteString -> Value
toB16JSON s = String $ toB16Text s

toB16Text :: ByteString -> Text
toB16Text s = decodeUtf8 $ B16.encode s

failMaybe :: Monad m => String -> Maybe a -> m a
failMaybe err m = maybe (fail err) return m



newtype EncryptionKey = EncryptionKey { unEncryptionKey :: ByteString }
  deriving (Show, Eq, Ord, Generic, Serialize)
instance ToJSON EncryptionKey where
  toJSON = toB16JSON . unEncryptionKey
instance FromJSON EncryptionKey where
  parseJSON s = EncryptionKey <$> parseB16JSON s


deriving instance Eq Signature
deriving instance Ord Signature
instance Serialize Signature where
  put (Sig s) = S.put s
  get = Sig <$> (S.get >>= S.getByteString)

instance Eq PublicKey where
  b == b' = exportPublic b == exportPublic b'
instance Ord PublicKey where
  b <= b' = exportPublic b <= exportPublic b'
instance ToJSON PublicKey where
  toJSON = toB16JSON . exportPublic
instance FromJSON PublicKey where
  parseJSON s = do
    s' <- parseB16JSON s
    failMaybe ("Public key import failed: " ++ show s) $ importPublic s'

instance (ToJSON k,ToJSON v) => ToJSON (Map k v) where
  toJSON = toJSON . Map.toList
instance (FromJSON k,Ord k,FromJSON v) => FromJSON (Map k v) where
  parseJSON = fmap Map.fromList . parseJSON

instance Eq PrivateKey where
  b == b' = exportPrivate b == exportPrivate b'
instance Ord PrivateKey where
  b <= b' = exportPrivate b <= exportPrivate b'
instance ToJSON PrivateKey where
  toJSON = toB16JSON . exportPrivate
instance FromJSON PrivateKey where
  parseJSON s = do
    s' <- parseB16JSON s
    failMaybe ("Private key import failed: " ++ show s) $ importPrivate s'


instance ToJSON (Map NodeId PrivateKey) where
  toJSON = toJSON . Map.toList
instance FromJSON (Map NodeId PrivateKey) where
  parseJSON = fmap Map.fromList . parseJSON

-- These instances suck, but I can't figure out how to use the Get monad to fail out if not
-- length = 32. For the record, if the getByteString 32 works the imports will not fail
instance Serialize PublicKey where
  put s = S.putByteString (exportPublic s)
  get = fromMaybe (error "Invalid PubKey") . importPublic <$> S.getByteString (32::Int)
instance Serialize PrivateKey where
  put s = S.putByteString (exportPrivate s)
  get = fromMaybe (error "Invalid PubKey") . importPrivate <$> S.getByteString (32::Int)

-- | UTCTime from Thyme of when ZMQ received the message
newtype ReceivedAt = ReceivedAt {_unReceivedAt :: UTCTime}
  deriving (Show, Eq, Ord, Generic)
instance Serialize ReceivedAt

interval :: UTCTime -> UTCTime -> Int64
interval start end = view microseconds $ end .-. start

data Role = Follower
          | Candidate
          | Leader
  deriving (Show, Generic, Eq)
