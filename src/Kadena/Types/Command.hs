{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}

module Kadena.Types.Command
  ( CommandEntry(..)
  , CommandResult(..)
  , RequestKey(..), initialRequestKey
  , AppliedCommand(..),acResult,acLatency,acRequestId
  ) where

import Data.ByteString (ByteString)
import Data.Serialize (Serialize)
import Data.Aeson
import qualified Data.Aeson as A
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import GHC.Generics hiding (from)
import GHC.Int (Int64)
import Control.Lens (makeLenses)

import Kadena.Types.Base

newtype CommandEntry = CommandEntry { unCommandEntry :: ByteString }
  deriving (Show, Eq, Ord, Generic, Serialize)

newtype CommandResult = CommandResult { unCommandResult :: ByteString }
  deriving (Show, Eq, Ord, Generic, Serialize)
instance ToJSON CommandResult where
  toJSON (CommandResult a) = toJSON $ decodeUtf8 a
instance FromJSON CommandResult where
  parseJSON (A.String t) = return $ CommandResult (encodeUtf8 t)
  parseJSON _ = mempty

newtype RequestKey = RequestKey { unRequestKey :: Hash}
  deriving (Eq, Ord, Generic, ToJSON, FromJSON, Serialize)

instance Show RequestKey where
  show (RequestKey rk) = show rk

initialRequestKey :: RequestKey
initialRequestKey = RequestKey initialHash

data AppliedCommand = AppliedCommand {
      _acResult :: !CommandResult
    , _acLatency :: !Int64
    , _acRequestId :: !RequestId
    } deriving (Eq,Show)
makeLenses ''AppliedCommand
