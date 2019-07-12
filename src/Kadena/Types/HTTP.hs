{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
-- TODO: remove this when the instance is moved to Pact
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Kadena.Types.HTTP
  ( ApiResponse
  , PollResponses(..)
  ) where

import Data.Aeson
import qualified Data.HashMap.Strict as HM

import Pact.Types.Command (RequestKey(..))

import Kadena.Types.Command (CommandResult(..))

type ApiResponse a = Either String a

newtype PollResponses = PollResponses (HM.HashMap RequestKey (ApiResponse CommandResult))
  deriving (ToJSON, FromJSON)

--TODO: add this to Pact (Pact.Types.Command.hs)
instance FromJSONKey RequestKey
