{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-} -- TODO: remove this when the instance is moved to Pact

module Kadena.Types.HTTP
  ( PollResponses(..)
  ) where

import Control.Arrow
import Control.Monad

import Data.Aeson
import qualified Data.HashMap.Strict as HM

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

--TODO: add this to Pact (Pact.Types.Command.hs)
instance FromJSONKey RequestKey
