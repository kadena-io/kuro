{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.History.Types
  ( ApplyFn
  , History(..)
  , HistoryEnv(..)
  , commitChannel, applyLogEntry, debugPrint, publishMetric
  , getTimestamp, publishResults
  , HistoryState(..)
  , nodeId, keySet
  , HistoryChannel(..)
  , HistoryService
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

data History =
  AddNew
    { logEntriesToApply :: !LogEntries } |
  Update
    { logEntriesToApply :: !LogEntries } |
  Query
    { logEntriesToApply :: !LogEntries } |
  RegisterListener
    { newNodeId :: !NodeId } |
  Tick Tock

newtype HistoryChannel = HistoryChannel (Chan History)

instance Comms History HistoryChannel where
  initComms = HistoryChannel <$> initCommsNormal
  readComm (HistoryChannel c) = readCommNormal c
  writeComm (HistoryChannel c) = writeCommNormal c

data HistoryEnv = HistoryEnv
  { _commitChannel :: !HistoryChannel
    -- ^ Function to apply a log entry to the state machine.
  , _applyLogEntry    :: !ApplyFn
  , _debugPrint :: !(String -> IO ())
  , _publishMetric :: !(Metric -> IO ())
  , _getTimestamp :: !(IO UTCTime)
  , _publishResults :: !(AppliedCommand -> IO ())
  }
makeLenses ''HistoryEnv

data HistoryState = HistoryState
  { _nodeId :: !NodeId
  , _keySet :: !KeySet
  }
makeLenses ''HistoryState

type HistoryService = RWST HistoryEnv () HistoryState IO
