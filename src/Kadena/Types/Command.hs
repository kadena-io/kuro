{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}

module Kadena.Types.Command
  ( CommandEntry(..)
  , CommandResult(..)
  , CommandStatus(..)
  , CommandMap(..), CommandMVarMap, initCommandMap, setNextCmdRequestId
  , EncryptionKey(..)
  , AppliedCommand(..),acResult,acLatency,acRequestId
  ) where

import Control.Concurrent (MVar, newMVar, takeMVar, putMVar)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.ByteString (ByteString)
import Data.Serialize (Serialize)
import Data.Thyme.Clock
import Data.Thyme.Time.Core (unUTCTime, toMicroseconds)
import GHC.Generics hiding (from)
import GHC.Int (Int64)
import Control.Lens (makeLenses)

import Kadena.Types.Base

-- Shared between API and Kadena protocol
-- holds the command result when the status is CmdApplied
data CommandMap = CommandMap
  { _cmvNextRequestId :: RequestId
  , _cmvMap :: Map RequestId CommandStatus
  } deriving (Show)

type CommandMVarMap = MVar CommandMap

initCommandMap :: IO CommandMVarMap
initCommandMap = do
  UTCTime _ time <- unUTCTime <$> getCurrentTime
  newMVar $ CommandMap (RequestId $ toMicroseconds time) Map.empty

setNextCmdRequestId :: CommandMVarMap -> IO RequestId
setNextCmdRequestId cmdStatusMap = do
  (CommandMap nextId m) <- takeMVar cmdStatusMap
  putMVar cmdStatusMap $ CommandMap (nextId + 1) (Map.insert nextId CmdSubmitted m)
  return nextId

newtype CommandEntry = CommandEntry { unCommandEntry :: ByteString }
  deriving (Show, Eq, Ord, Generic, Serialize)

newtype CommandResult = CommandResult { unCommandResult :: ByteString }
  deriving (Show, Eq, Ord, Generic, Serialize)

data CommandStatus = CmdSubmitted -- client sets when sending command
                   | CmdAccepted  -- Consensus client has recieved command and submitted
                   | CmdApplied { result :: CommandResult, cmdaLatencty :: Int64 }  -- We have a result
                   deriving (Show)

data AppliedCommand = AppliedCommand {
      _acResult :: CommandResult
    , _acLatency :: Int64
    , _acRequestId :: RequestId
    } deriving (Eq,Show)
makeLenses ''AppliedCommand
