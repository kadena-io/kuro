{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}

module Kadena.Types.Command
  ( CommandEntry(..)
  , CommandResult(..)
  , AppliedCommand(..),acResult,acLatency,acRequestId
  ) where

import Data.ByteString (ByteString)
import Data.Serialize (Serialize)
import GHC.Generics hiding (from)
import GHC.Int (Int64)
import Control.Lens (makeLenses)

import Kadena.Types.Base

newtype CommandEntry = CommandEntry { unCommandEntry :: ByteString }
  deriving (Show, Eq, Ord, Generic, Serialize)

newtype CommandResult = CommandResult { unCommandResult :: ByteString }
  deriving (Show, Eq, Ord, Generic, Serialize)

data AppliedCommand = AppliedCommand {
      _acResult :: !CommandResult
    , _acLatency :: !Int64
    , _acRequestId :: !RequestId
    } deriving (Eq,Show)
makeLenses ''AppliedCommand
