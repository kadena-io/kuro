{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-} -- TODO: remove this when the instance is moved to Pact

module Kadena.Types.HTTP
  ( ApiResponse
  , ListenResponse(..)
  , PollResponses(..)
  ) where

import Control.Applicative ((<|>))

import Data.Aeson
import qualified Data.HashMap.Strict as HM
import Data.Text (Text)

import GHC.Generics

import Pact.Types.Command (RequestKey(..))

import Kadena.Types.Command as K (CommandResult(..))

type ApiResponse a = Either String a

newtype PollResponses = PollResponses (HM.HashMap RequestKey (ApiResponse CommandResult))
  deriving (Generic, ToJSON, FromJSON)

data ListenResponse  =
  ListenTimeout Int
  | ListenResponse K.CommandResult

instance ToJSON ListenResponse where
  toJSON (ListenResponse r) = toJSON r
  toJSON (ListenTimeout i) =
    object [ "status" .= ("timeout" :: String),
             "timeout-micros" .= i ]
instance FromJSON ListenResponse where
  parseJSON v =
    (ListenResponse <$> parseJSON v) <|>
    (ListenTimeout <$> parseTimeout v)
    where
      parseTimeout = withObject "ListenTimeout" $ \o -> do
        (s :: Text) <- o .: "status"
        case s of
          "timeout" -> o .: "timeout-micros"
          _ -> fail "Expected timeout status"

--TODO: add this to Pact (Pact.Types.Command.hs)
instance FromJSONKey RequestKey
