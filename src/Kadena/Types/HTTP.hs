{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# OPTIONS_GHC -fno-warn-orphans #-} -- TODO: remove this when the instance is moved to Pact

module Kadena.Types.HTTP
  ( ApiResponse
  , ListenResponse(..)
  , PollResponses(..)
  ) where

import Data.Aeson
import qualified Data.HashMap.Strict as HM

import GHC.Generics

import Pact.Types.Command (RequestKey(..))

import Kadena.Types.Command as K (CommandResult(..))

type ApiResponse a = Either String a

newtype PollResponses = PollResponses (HM.HashMap RequestKey (ApiResponse CommandResult))
  deriving (Generic, ToJSON, FromJSON)

data ListenResponse  =
  ListenTimeout Int
  | ListenResponse K.CommandResult
    deriving (Generic, ToJSON, FromJSON)

--TODO: add this to Pact (Pact.Types.Command.hs)
instance FromJSONKey RequestKey
