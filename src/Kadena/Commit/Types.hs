{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.Commit.Types
  ( ApplyFn
  , Commit(..)
  , CommitEnv(..)
  , commitChannel, debugPrint, publishMetric
  , getTimestamp, historyChannel, mConfig
  , pactPersistConfig, pactConfig, commitLoggers
  , privateChannel
  , CommitState(..)
  , csNodeId,csKeySet,csCommandExecInterface
  , CommitChannel(..)
  , CommitService
  , PactState(..),psRefStore
  , PactEnv(..),peConfig,peMode,peDbEnv,peState
  , PactM, runPact
  ) where

import Control.Lens hiding (Index)

import Control.Monad.Trans.RWS.Strict (RWST)
import Control.Monad.Reader (ReaderT,runReaderT)
import Control.Concurrent.Chan (Chan)
import Control.Concurrent (MVar)

import Data.Thyme.Clock (UTCTime)
import Data.ByteString (ByteString)
import Data.Aeson (Value)

import Pact.Types.Command (ExecutionMode,ParsedCode,CommandExecInterface)
import qualified Pact.Types.Command as Pact (CommandResult,Command)
import Pact.Types.Runtime (RefStore)
import Pact.Types.Logger (Loggers)
import Pact.Types.RPC (PactConfig,PactRPC)
import Pact.Interpreter (PactDbEnv)


import Kadena.Types.Base (NodeId)
import Kadena.Types.Config (PactPersistConfig,GlobalConfigTMVar,KeySet)
import Kadena.Types.Comms (Comms(..),initCommsNormal,readCommNormal,writeCommNormal)
import Kadena.Types.Metric (Metric)
import Kadena.Types.Log (LogEntry,LogEntries)

import Kadena.Types.Event (Beat)

import Kadena.History.Types (HistoryChannel)
import Kadena.Private.Types (PrivateChannel)

type ApplyFn = LogEntry -> IO Pact.CommandResult

data Commit =
  ReloadFromDisk
    { logEntriesToApply :: !LogEntries } |
  CommitNewEntries
    { logEntriesToApply :: !LogEntries } |
  ChangeNodeId
    { newNodeId :: !NodeId } |
  UpdateKeySet
    { newKeySet :: !KeySet } |
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
  , _privateChannel :: !PrivateChannel
  , _pactPersistConfig :: !PactPersistConfig
  , _pactConfig :: !PactConfig
  , _debugPrint :: !(String -> IO ())
  , _commitLoggers :: !Loggers
  , _publishMetric :: !(Metric -> IO ())
  , _getTimestamp :: !(IO UTCTime)
  , _mConfig :: GlobalConfigTMVar
  }
makeLenses ''CommitEnv

data CommitState = CommitState
  { _csNodeId :: !NodeId
  , _csKeySet :: !KeySet
  , _csCommandExecInterface :: !(CommandExecInterface (PactRPC ParsedCode))
  }
makeLenses ''CommitState

type CommitService = RWST CommitEnv () CommitState IO

data PactState = PactState {
  _psRefStore :: RefStore
  }
makeLenses ''PactState

data PactEnv p = PactEnv {
      _peConfig :: PactConfig
    , _peMode :: ExecutionMode
    , _peDbEnv :: PactDbEnv p
    , _peState :: MVar PactState
    }
$(makeLenses ''PactEnv)

type PactM p a = ReaderT (PactEnv p) IO a

runPact :: PactEnv p -> (PactM p a) -> IO a
runPact e a = runReaderT a e
