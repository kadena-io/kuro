{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.Execution.Types
  ( ApplyFn
  , Execution(..)
  , ExecutionEnv(..)
  , execChannel, debugPrint, publishMetric
  , getTimestamp, historyChannel, mConfig
  , pactPersistConfig, execLoggers, entityConfig
  , privateChannel
  , ExecutionState(..)
  , csNodeId,csKeySet,csCommandExecInterface
  , ExecutionChannel(..)
  , ExecutionService
  ) where

import Control.Lens hiding (Index)

import Control.Monad.Trans.RWS.Strict (RWST)
import Control.Concurrent.Chan (Chan)
import Control.Concurrent (MVar)

import Data.Thyme.Clock (UTCTime)
import Data.ByteString (ByteString)
import Data.Aeson (Value)

import Pact.Types.Command (ParsedCode,CommandExecInterface)
import qualified Pact.Types.Command as Pact (CommandResult,Command)
import Pact.Types.Logger (Loggers)
import Pact.Types.RPC (PactRPC)

import Kadena.Types.Base (NodeId)
import Kadena.Types.PactDB
import Kadena.Types.Config (GlobalConfigTMVar)
import Kadena.Types.Comms (Comms(..),initCommsNormal,readCommNormal,writeCommNormal)
import Kadena.Types.KeySet
import Kadena.Types.Metric (Metric)
import Kadena.Types.Log (LogEntry,LogEntries)
import Kadena.Types.Event (Beat)
import Kadena.Types.History (HistoryChannel)
import Kadena.Private.Types (PrivateChannel)
import Kadena.Types.Entity (EntityConfig)

type ApplyFn = LogEntry -> IO Pact.CommandResult

data Execution =
  ReloadFromDisk { logEntriesToApply :: !LogEntries } |
  ExecuteNewEntries { logEntriesToApply :: !LogEntries } |
  ChangeNodeId { newNodeId :: !NodeId } |
  UpdateKeySet { newKeySet :: !KeySet } |
  Heart Beat |
  ExecLocal { localCmd :: !(Pact.Command ByteString),
              localResult :: !(MVar Value) } |
  ExecConfigChange { logEntriesToApply :: !LogEntries }

newtype ExecutionChannel = ExecutionChannel (Chan Execution)

instance Comms Execution ExecutionChannel where
  initComms = ExecutionChannel <$> initCommsNormal
  readComm (ExecutionChannel c) = readCommNormal c
  writeComm (ExecutionChannel c) = writeCommNormal c

data ExecutionEnv = ExecutionEnv
  { _execChannel :: !ExecutionChannel
  , _historyChannel :: !HistoryChannel
  , _privateChannel :: !PrivateChannel
  , _pactPersistConfig :: !PactPersistConfig
  , _debugPrint :: !(String -> IO ())
  , _execLoggers :: !Loggers
  , _publishMetric :: !(Metric -> IO ())
  , _getTimestamp :: !(IO UTCTime)
  , _mConfig :: GlobalConfigTMVar
  , _entityConfig :: !EntityConfig
  }
makeLenses ''ExecutionEnv

data ExecutionState = ExecutionState
  { _csNodeId :: !NodeId
  , _csKeySet :: !KeySet
  , _csCommandExecInterface :: !(CommandExecInterface (PactRPC ParsedCode))
  }
makeLenses ''ExecutionState

type ExecutionService = RWST ExecutionEnv () ExecutionState IO
