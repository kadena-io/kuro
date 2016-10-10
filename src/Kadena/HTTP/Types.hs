{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.HTTP.Types
  ( ApiStatus(..)
  , ApiResponse(..), apiStatus, apiResponse
  , RequestKeys(..), rkRequestKeys
  , SubmitBatch(..), sbCmds
  , SubmitBatchResponse(..)
  , Poll(..)
  , PollResult(..), prRequestKey, prLatency, prResponse
  , PollResponse(..)
  , ListenerRequest(..)
  , ListenerResponse(..)
  ) where

import Data.Char (toLower)
import Data.Aeson hiding (Success)
import Data.Aeson.Types (Options(..))
import Control.Lens hiding ((.=))
import GHC.Generics
import Data.Int

import Kadena.Command.Types
import Kadena.Types.Command

lensyConstructorToNiceJson :: Int -> String -> String
lensyConstructorToNiceJson n fieldName = firstToLower $ drop n fieldName
  where
    firstToLower (c:cs) = toLower c : cs
    firstToLower _ = error "You've managed to screw up the drop number or the field name"

data ApiStatus = Success | Failure
  deriving (Eq, Show, Ord, Generic)
instance ToJSON ApiStatus where
  toEncoding = genericToEncoding defaultOptions
instance FromJSON ApiStatus

data ApiResponse a = ApiResponse
  { _apiStatus :: !ApiStatus
  , _apiResponse :: !a
  } deriving (Show, Eq, Generic)
makeLenses ''ApiResponse

instance ToJSON a => ToJSON (ApiResponse a) where
  toEncoding = genericToEncoding (defaultOptions {fieldLabelModifier = lensyConstructorToNiceJson 4})
instance FromJSON a => FromJSON (ApiResponse a)

data RequestKeys = RequestKeys
  { _rkRequestKeys :: ![RequestKey]
  } deriving (Show, Eq, Ord, Generic)
makeLenses ''RequestKeys

instance ToJSON RequestKeys where
  toEncoding = genericToEncoding (defaultOptions {fieldLabelModifier = lensyConstructorToNiceJson 3})
instance FromJSON RequestKeys

-- | Submit new commands for execution
data SubmitBatch = SubmitBatch
  { _sbCmds :: ![PactMessage]
  } deriving (Eq,Generic)
makeLenses ''SubmitBatch
instance ToJSON SubmitBatch where
  toEncoding = genericToEncoding (defaultOptions {fieldLabelModifier = lensyConstructorToNiceJson 3})
instance FromJSON SubmitBatch

-- | What you get back from a SubmitBatch
data SubmitBatchResponse =
  SubmitBatchSuccess (ApiResponse RequestKeys) |
  SubmitBatchFailure (ApiResponse String)
  deriving (Show, Eq, Generic)
instance ToJSON SubmitBatchResponse where
  toEncoding = genericToEncoding defaultOptions
instance FromJSON SubmitBatchResponse

-- | Poll for results by RequestKey
newtype Poll = Poll [RequestKey]
  deriving (Eq,Show,Generic)
instance ToJSON Poll where
  toEncoding = genericToEncoding defaultOptions
instance FromJSON Poll

-- | What you get back from a Poll
data PollResult = PollResult
  { _prRequestKey :: !RequestKey
  , _prLatency :: !Int64
  , _prResponse :: !CommandResult
  } deriving (Eq,Show,Generic)
makeLenses ''PollResult
instance ToJSON PollResult where
  toEncoding = genericToEncoding (defaultOptions {fieldLabelModifier = lensyConstructorToNiceJson 3})
instance FromJSON PollResult

data PollResponse =
  PollSuccess (ApiResponse [PollResult]) |
  PollFailure (ApiResponse String)
  deriving (Show, Eq, Generic)
instance ToJSON PollResponse where
  toEncoding = genericToEncoding defaultOptions
instance FromJSON PollResponse

-- | ListenerRequest for results by RequestKey
newtype ListenerRequest = ListenerRequest RequestKey
  deriving (Eq,Show,Generic)
instance ToJSON ListenerRequest where
  toEncoding = genericToEncoding defaultOptions
instance FromJSON ListenerRequest

data ListenerResponse =
  ListenerSuccess (ApiResponse PollResult) |
  ListenerFailure (ApiResponse String)
  deriving (Show, Eq, Generic)
instance ToJSON ListenerResponse where
  toEncoding = genericToEncoding defaultOptions
instance FromJSON ListenerResponse
