{-# LANGUAGE OverloadedStrings #-}
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
  , interval, printLatTime, printInterval
  , hash, hashLengthAsBS, hashLengthAsBase16
  , Hash(..), initialHash
  , NodeClass(..)
  , ConfigVersion(..), initialConfigVersion
  ) where

import Control.DeepSeq
import Control.Lens
import Control.Monad (mzero)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC
import Data.String

import Data.AffineSpace ((.-.))
import Data.Thyme.Clock

import Data.Serialize (Serialize)
import Data.Aeson

import Data.Word (Word64)
import GHC.Int (Int64)
import GHC.Generics hiding (from)

import Pact.Types.Orphans ()
import Pact.Types.Crypto
import Pact.Types.Util
import Pact.Types.Command (RequestKey(..), initialRequestKey)
import Pact.Types.Hash


newtype Alias = Alias { unAlias :: ByteString }
  deriving (Eq, Ord, Generic, Serialize, ToJSON, ToJSONKey, FromJSON, FromJSONKey)
instance IsString Alias where fromString s = Alias $ BSC.pack s
instance NFData Alias

instance Show Alias where
  show (Alias a) = BSC.unpack a


data NodeId = NodeId { _host :: !String, _port :: !Word64, _fullAddr :: !String, _alias :: !Alias}
  deriving (Eq,Ord,Generic)
instance Show NodeId where
  show nid = "NodeId: " ++ BSC.unpack (unAlias $ _alias nid)
instance Serialize NodeId
instance ToJSON NodeId where
  toJSON = genericToJSON defaultOptions { fieldLabelModifier = drop 1 }
instance FromJSON NodeId where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 1 }
instance NFData NodeId

newtype Term = Term Int
  deriving (Show, Read, Eq, Enum, Num, Ord, Generic, Serialize, ToJSON, FromJSON)

startTerm :: Term
startTerm = Term (-1)

newtype LogIndex = LogIndex Int
  deriving (Show, Read, Eq, Ord, Enum, Num, Real, Integral, Generic, Serialize, ToJSON, FromJSON)

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


-- | UTCTime from Thyme of when ZMQ received the message
newtype ReceivedAt = ReceivedAt {_unReceivedAt :: UTCTime}
  deriving (Show, Eq, Ord, Generic)
instance Serialize ReceivedAt

interval :: UTCTime -> UTCTime -> Int64
interval start end = view microseconds $ end .-. start
{-# INLINE interval #-}

printLatTime :: (Num a, Ord a, Show a) => a -> String
printLatTime s
  | s >= 1000000 =
      let s' = drop 4 $ reverse $ show s
          s'' = reverse $ (take 2 s') ++ "." ++ (drop 2 s')
      in s'' ++ "sec"
  | s >= 1000 =
      let s' = drop 1 $ reverse $ show s
          s'' = reverse $ (take 2 s') ++ "." ++ (drop 2 s')
      in s'' ++ "msec"
  | otherwise = show s ++ "usec"
{-# INLINE printLatTime #-}

printInterval :: UTCTime -> UTCTime -> String
printInterval st ed = printLatTime $! interval st ed
{-# INLINE printInterval #-}

data Role = Follower
          | Candidate
          | Leader
  deriving (Show, Generic, Eq)

data NodeClass = Active | Passive
  deriving (Show, Eq, Ord, Generic)

instance Serialize NodeClass
instance ToJSON NodeClass where
  toJSON Active = String "active"
  toJSON Passive = String "passive"
instance FromJSON NodeClass where
  parseJSON (String s)
    | s == "active" = return $ Active
    | s == "passive" = return $ Passive
    | otherwise = mzero
  parseJSON _ = mzero

newtype ConfigVersion = ConfigVersion {configVersion :: Int}
  deriving (Show, Eq, Ord)

initialConfigVersion :: ConfigVersion
initialConfigVersion = ConfigVersion 0
