{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Log.Types
  ( LogState(..)
  , lsVolatileLogEntries, lsPersistedLogEntries, lsLastApplied, lsLastLogIndex, lsNextLogIndex, lsCommitIndex
  , lsLastPersisted, lsLastLogTerm, lsLastLogHash, lsLastInMemory
  , initLogState
  , LogEnv(..)
  , logQueryChannel, commitChannel, internalEvent, senderChannel, debugPrint
  , dbConn, evidence, publishMetric
  , persistedLogEntriesToKeepInMemory
  , LogThread
  , LogServiceChannel(..)
  , UpdateLogs(..)
  , QueryApi(..)
  -- ReExports
  , module X
  , LogIndex(..)
  , KeySet(..)
  -- for tesing
  ) where

import Control.Lens hiding (Index, (|>))

import Control.Concurrent (MVar)
import Control.Concurrent.Chan (Chan)
import Control.Monad.Trans.RWS.Strict

import Data.Map.Strict (Map)
import Data.Set (Set)

import Database.SQLite.Simple (Connection(..))

import GHC.Generics

import Kadena.Types.Base as X
import Kadena.Types.Metric
import Kadena.Types.Config (KeySet(..))
import Kadena.Types.Log
import qualified Kadena.Types.Log as X
import Kadena.Types.Comms

import Kadena.Types.Event (Beat,InternalEventChannel)

import Kadena.Evidence.Types (EvidenceChannel)
import Kadena.Commit.Types (CommitChannel)
import Kadena.Sender.Types (SenderServiceChannel)

data QueryApi =
  Query (Set AtomicQuery) (MVar (Map AtomicQuery QueryResult)) |
  Update UpdateLogs |
  NeedCacheEvidence (Set LogIndex) (MVar (Map LogIndex Hash)) |
  Heart Beat
  deriving (Eq)

newtype LogServiceChannel = LogServiceChannel (Chan QueryApi)

instance Comms QueryApi LogServiceChannel where
  initComms = LogServiceChannel <$> initCommsNormal
  readComm (LogServiceChannel c) = readCommNormal c
  writeComm (LogServiceChannel c) = writeCommNormal c

data LogEnv = LogEnv
  { _logQueryChannel :: !LogServiceChannel
  , _internalEvent :: !InternalEventChannel
  , _commitChannel :: !CommitChannel
  , _evidence :: !EvidenceChannel
  , _senderChannel :: !SenderServiceChannel
  , _persistedLogEntriesToKeepInMemory :: !Int
  , _debugPrint :: !(String -> IO ())
  , _dbConn :: !(Maybe Connection)
  , _publishMetric :: !(Metric -> IO ())}
makeLenses ''LogEnv

data LogState = LogState
  { _lsVolatileLogEntries  :: !LogEntries
  , _lsPersistedLogEntries :: !PersistedLogEntries
  , _lsLastApplied      :: !LogIndex
  , _lsLastLogIndex     :: !LogIndex
  , _lsLastLogHash      :: !Hash
  , _lsNextLogIndex     :: !LogIndex
  , _lsCommitIndex      :: !LogIndex
  , _lsLastPersisted    :: !LogIndex
  , _lsLastInMemory     :: !(Maybe LogIndex)
  , _lsLastLogTerm      :: !Term
  } deriving (Show, Eq, Generic)
makeLenses ''LogState

initLogState :: LogState
initLogState = LogState
  { _lsVolatileLogEntries = lesEmpty
  , _lsPersistedLogEntries = plesEmpty
  , _lsLastApplied = startIndex
  , _lsLastLogIndex = startIndex
  , _lsLastLogHash = initialHash
  , _lsNextLogIndex = startIndex + 1
  , _lsCommitIndex = startIndex
  , _lsLastPersisted = startIndex
  , _lsLastInMemory = Nothing
  , _lsLastLogTerm = startTerm
  }

type LogThread = RWST LogEnv () LogState IO
