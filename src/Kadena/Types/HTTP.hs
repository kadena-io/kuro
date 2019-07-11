{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.HTTP
  ( ApiResponse
  , PollResponses(..)
  ) where

import Control.Lens
import Control.Monad.Trans.Reader
import Data.Aeson
import qualified Data.HashMap.Strict as HM
import Snap.Core

import Pact.Types.Command (RequestKey(..))

import Kadena.Types.Command (CommandResult(..))

type ApiResponse a = Either String a

newtype PollResponses = PollResponses (HM.HashMap RequestKey (ApiResponse CommandResult))
  deriving (ToJSON, FromJSON)

instance FromJSONKey RequestKey
