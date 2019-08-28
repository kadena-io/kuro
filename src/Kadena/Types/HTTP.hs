{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-} -- TODO: remove this when the instance is moved to Pact

module Kadena.Types.HTTP
  ( ListenResponse(..)
  , PollResponses(..)
  ) where

import Control.Applicative ((<|>))
import Control.Arrow
import Control.Monad

import Data.Aeson
import qualified Data.HashMap.Strict as HM
import Data.Text (Text)

import GHC.Generics

import Pact.Types.Command as Pact

import Kadena.Types.Command as K (CommandResult(..))

newtype PollResponses = PollResponses (HM.HashMap RequestKey K.CommandResult)
  deriving (Eq, Show, Generic)

instance ToJSON PollResponses where
  toJSON (PollResponses m) = object $ map (Pact.requestKeyToB16Text *** toJSON) $ HM.toList m
instance FromJSON PollResponses where
  parseJSON = withObject "PollResponses" $ \o ->
    (PollResponses . HM.fromList <$> forM (HM.toList o)
      (\(k,v) -> (,) <$> parseJSON (String k) <*> parseJSON v))

data ListenResponse  =
  ListenTimeout Int
  | ListenResponse K.CommandResult
  deriving Show

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
