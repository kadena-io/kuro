{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.Commit.Types
  ( ApplyFn
  , Commit(..)
  , CommitEnv(..)
  , commitChannel, commandConfig, debugPrint, publishMetric
  , getTimestamp, historyChannel, enableWB
  , CommitState(..)
  , nodeId, keySet, commandExecInterface
  , CommitChannel(..)
  , CommitService
  , module X
  ) where

import Control.Lens hiding (Index)

import Control.Monad.Trans.RWS.Strict
import Control.Concurrent.Chan (Chan)
import Control.Concurrent (MVar)

import Data.Thyme.Clock (UTCTime)
import Data.ByteString (ByteString)
import Data.Aeson (Value)

import qualified Pact.Types.Command as Pact
import qualified Pact.Types.Server as Pact
import qualified Pact.Types.RPC as Pact

import Kadena.Types.Base as X
import Kadena.Types.Config as X hiding (nodeId, _nodeId)
import Kadena.Types.Command as X
import Kadena.Types.Comms as X
import Kadena.Types.Metric as X
import Kadena.Types.Log as X
import Kadena.Types.Message as X

import Kadena.History.Types (HistoryChannel)

type ApplyFn = LogEntry -> IO Pact.CommandResult

data Commit =
  ReloadFromDisk
    { logEntriesToApply :: !LogEntries } |
  CommitNewEntries
    { logEntriesToApply :: !LogEntries } |
  ChangeNodeId
    { newNodeId :: !NodeId } |
  UpdateKeySet
    { updateKeySet :: !(KeySet -> KeySet) } |
  Heart Beat |
  ExecLocal
    { localCmd :: !(Pact.Command ByteString),
      localResult :: !(MVar Value) }


newtype CommitChannel = CommitChannel (Chan Commit)

instance Comms Commit CommitChannel where
  initComms = CommitChannel <$> initCommsNormal
  readComm (CommitChannel c) = readCommNormal c
  writeComm (CommitChannel c) = writeCommNormal c

data CommitEnv = CommitEnv
  { _commitChannel :: !CommitChannel
  , _historyChannel :: !HistoryChannel
  , _commandConfig :: !Pact.CommandConfig
  , _debugPrint :: !(String -> IO ())
  , _publishMetric :: !(Metric -> IO ())
  , _getTimestamp :: !(IO UTCTime)
  , _enableWB :: !Bool
  }
makeLenses ''CommitEnv

data CommitState = CommitState
  { _nodeId :: !NodeId
  , _keySet :: !KeySet
  , _commandExecInterface :: !(Pact.CommandExecInterface (Pact.PactRPC Pact.ParsedCode))
  }
makeLenses ''CommitState

type CommitService = RWST CommitEnv () CommitState IO
