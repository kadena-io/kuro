{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.Commit.Types
  ( ApplyFn
  , Commit(..)
  , CommitEnv(..)
  , commitChannel, applyLogEntry, debugPrint, publishMetric
  , getTimestamp, historyChannel
  , CommitState(..)
  , nodeId, keySet
  , CommitChannel(..)
  , CommitService
  , module X
  ) where

import Control.Lens hiding (Index)

import Control.Monad.Trans.RWS.Strict
import Control.Concurrent.Chan (Chan)

import Data.Thyme.Clock (UTCTime)

import Kadena.Types.Base as X
import Kadena.Types.Config as X hiding (nodeId, _nodeId)
import Kadena.Types.Command as X
import Kadena.Types.Comms as X
import Kadena.Types.Metric as X
import Kadena.Types.Log as X
import Kadena.Types.Message as X

import Kadena.History.Types (HistoryChannel)

type ApplyFn = LogEntry -> IO CommandResult

data Commit =
  ReloadFromDisk
    { logEntriesToApply :: !LogEntries } |
  CommitNewEntries
    { logEntriesToApply :: !LogEntries } |
  ChangeNodeId
    { newNodeId :: !NodeId } |
  UpdateKeySet
    { updateKeySet :: !(KeySet -> KeySet) } |
  Tick Tock

newtype CommitChannel = CommitChannel (Chan Commit)

instance Comms Commit CommitChannel where
  initComms = CommitChannel <$> initCommsNormal
  readComm (CommitChannel c) = readCommNormal c
  writeComm (CommitChannel c) = writeCommNormal c

data CommitEnv = CommitEnv
  { _commitChannel :: !CommitChannel
  , _historyChannel :: !HistoryChannel
  , _applyLogEntry  :: !ApplyFn
  , _debugPrint :: !(String -> IO ())
  , _publishMetric :: !(Metric -> IO ())
  , _getTimestamp :: !(IO UTCTime)
  }
makeLenses ''CommitEnv

data CommitState = CommitState
  { _nodeId :: !NodeId
  , _keySet :: !KeySet
  }
makeLenses ''CommitState

type CommitService = RWST CommitEnv () CommitState IO
