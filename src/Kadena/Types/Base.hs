{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Kadena.Types.Base
  ( NodeId(..)
  , Term(..), startTerm
  , LogIndex(..), startIndex
  , RequestId(..)
  , RequestKey(..), initialRequestKey
  , ReceivedAt(..)
  -- for simplicity, re-export some core types that we need all over the place
  , parseB16JSON, toB16JSON, toB16Text, parseB16Text, failMaybe
  , PublicKey, PrivateKey, Signature(..), sign, valid, importPublic, importPrivate, exportPublic
  , Role(..)
  , EncryptionKey(..)
  , Alias(..)
  , interval
  , hash, hashLengthAsBS, hashLengthAsBase16
  , Hash(..), initialHash
  ) where

import Control.Lens
import Control.Monad (mzero)

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC
import Data.String

import Data.Map (Map)
import qualified Data.Map as Map

import Data.AffineSpace ((.-.))
import Data.Thyme.Clock

import Data.Serialize (Serialize)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Aeson
import Data.Aeson.Types
import Data.Hashable (Hashable)

import Data.Word (Word64)
import GHC.Int (Int64)
import GHC.Generics hiding (from)

import Pact.Types.Orphans ()
import Pact.Types.Crypto
import Pact.Types.Util

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
  deriving (Eq, Ord, Generic, Serialize, IsString, ToJSON, FromJSON)
instance Show RequestId where show (RequestId i) = i

newtype EncryptionKey = EncryptionKey { unEncryptionKey :: ByteString }
  deriving (Show, Eq, Ord, Generic, Serialize)
instance ToJSON EncryptionKey where
  toJSON = toB16JSON . unEncryptionKey
instance FromJSON EncryptionKey where
  parseJSON s = EncryptionKey <$> parseB16JSON s

instance ToJSON (Map NodeId PrivateKey) where
  toJSON = toJSON . Map.toList
instance FromJSON (Map NodeId PrivateKey) where
  parseJSON = fmap Map.fromList . parseJSON

newtype RequestKey = RequestKey { unRequestKey :: Hash}
  deriving (Eq, Ord, Generic, ToJSON, FromJSON, Serialize, Hashable)

instance Show RequestKey where
  show (RequestKey rk) = show rk

initialRequestKey :: RequestKey
initialRequestKey = RequestKey initialHash

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
