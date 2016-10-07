{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Types.Api
  ( PollRequest(..)
  , Batch(..)
  , SubmitSuccess(..), ssRequestKeys
  , PollSuccessEntry(..)
  ) where

import Data.Aeson
import Control.Lens hiding ((.=))
import Data.Text (pack)
import GHC.Generics
import Data.Int

import Kadena.Types.Base
import Kadena.Command.Types
import Kadena.Types.Command

data PollRequest = PollRequest
  { requestIds :: ![RequestId]
  } deriving (Eq,Show,Generic)
instance FromJSON PollRequest
instance ToJSON PollRequest

data Batch = Batch
  { cmds :: ![PactMessage]
  } deriving (Eq,Generic)
instance FromJSON Batch
instance ToJSON Batch

data SubmitSuccess = SubmitSuccess { _ssRequestKeys :: ![RequestKey] }
makeLenses ''SubmitSuccess

instance ToJSON SubmitSuccess where
  toJSON (SubmitSuccess rids) =
      object [ "status" .= pack "Success", "requestIds" .= rids ]
instance FromJSON SubmitSuccess where
  parseJSON = withObject "BatchSuccess" $ \o -> SubmitSuccess <$> o .: "requestIds"

data PollSuccessEntry = PollSuccessEntry {
    latency :: !Int64
  , response :: !Value
  } deriving (Eq,Show,Generic)
instance FromJSON PollSuccessEntry
