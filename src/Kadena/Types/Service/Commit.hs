{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.Types.Service.Commit
  ( ApplyFn
  , Commit(..)
  , CommitEnv(..)
  , commitChannel, applyLogEntry, debugPrint, publishMetric
  , getTimestamp, publishResults
  , CommitState(..)
  , nodeId, keySet
  , CommitChannel(..)
  , CommitService
  , module X
  ) where

import Control.Lens hiding (Index)

import Control.Monad.Trans.RWS.Strict
import qualified Control.Concurrent.Chan.Unagi as Unagi
import Control.Concurrent (MVar)

import Data.Thyme.Clock (UTCTime)

import Kadena.Types.Base as X
import Kadena.Types.Config as X hiding (nodeId, _nodeId)
import Kadena.Types.Command as X
import Kadena.Types.Comms as X
import Kadena.Types.Metric as X
import Kadena.Types.Log as X
import Kadena.Types.Message as X

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

newtype CommitChannel =
  CommitChannel (Unagi.InChan Commit, MVar (Maybe (Unagi.Element Commit, IO Commit), Unagi.OutChan Commit))

instance Comms Commit CommitChannel where
  initComms = CommitChannel <$> initCommsUnagi
  readComm (CommitChannel (_,o)) = readCommUnagi o
  readComms (CommitChannel (_,o)) = readCommsUnagi o
  writeComm (CommitChannel (i,_)) = writeCommUnagi i

data CommitEnv = CommitEnv
  { _commitChannel :: !CommitChannel
    -- ^ Function to apply a log entry to the state machine.
  , _applyLogEntry    :: !ApplyFn
  , _debugPrint :: !(String -> IO ())
  , _publishMetric :: !(Metric -> IO ())
  , _getTimestamp :: !(IO UTCTime)
  , _publishResults :: !(AppliedCommand -> IO ())
  }
makeLenses ''CommitEnv

data CommitState = CommitState
  { _nodeId :: !NodeId
  , _keySet :: !KeySet
  }
makeLenses ''CommitState

type CommitService = RWST CommitEnv () CommitState IO
