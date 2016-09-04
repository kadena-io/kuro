{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Types.Api where

import Data.Aeson
import Control.Lens hiding ((.=))
import Data.Text (pack)
import GHC.Generics
import Data.Int

import Kadena.Types.Base
import Kadena.Command.Types

data PollRequest = PollRequest {
      requestIds :: [RequestId]
    } deriving (Eq,Show,Generic)
instance FromJSON PollRequest
instance ToJSON PollRequest

data Batch = Batch {
      cmds :: [PactRPC]
    } deriving (Eq,Show,Generic)
instance FromJSON Batch
instance ToJSON Batch


data SubmitSuccess = SubmitSuccess { _ssRequestIds :: [RequestId] }
makeLenses ''SubmitSuccess

instance ToJSON SubmitSuccess where
    toJSON (SubmitSuccess rids) =
        object [ "status" .= pack "Success", "requestIds" .= rids ]
instance FromJSON SubmitSuccess where
    parseJSON = withObject "BatchSuccess" $ \o -> SubmitSuccess <$> o .: "requestIds"

data PollSuccessEntry = PollSuccessEntry {
      latency :: Int64
    , response :: Value
    } deriving (Eq,Show,Generic)
instance FromJSON PollSuccessEntry
