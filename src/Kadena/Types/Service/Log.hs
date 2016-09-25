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

module Kadena.Types.Service.Log
  ( LogState(..)
  , lsVolatileLogEntries, lsPersistedLogEntries, lsLastApplied, lsLastLogIndex, lsNextLogIndex, lsCommitIndex
  , lsLastPersisted, lsLastLogTerm, lsLastLogHash, lsLastCryptoVerified, lsLastInMemory
  , initLogState
  , LogEnv(..)
  , logQueryChannel, commitChannel, internalEvent, debugPrint
  , dbConn, evidence, keySet, publishMetric, cryptoWorkerTVar
  , LogThread
  , LogServiceChannel(..)
  , UpdateLogs(..)
  , QueryApi(..)
  , CryptoWorkerStatus(..)
  -- ReExports
  , module X
  , LogIndex(..)
  , KeySet(..)
  -- for tesing
  ) where

import Control.Lens hiding (Index, (|>))

import Control.Concurrent (MVar)
import Control.Concurrent.STM.TVar (TVar)
import qualified Control.Concurrent.Chan.Unagi as Unagi
import Control.Monad.Trans.RWS.Strict

import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.ByteString (ByteString)

import Database.SQLite.Simple (Connection(..))

import GHC.Generics

import Kadena.Types.Base
import Kadena.Types.Metric
import Kadena.Types.Config (KeySet(..))
import Kadena.Types.Log
import qualified Kadena.Types.Log as X
import Kadena.Types.Comms

import Kadena.Types.Evidence (EvidenceChannel)
import Kadena.Types.Service.Commit (CommitChannel)

data QueryApi =
  Query (Set AtomicQuery) (MVar (Map AtomicQuery QueryResult)) |
  Update UpdateLogs |
  NeedCacheEvidence (Set LogIndex) (MVar (Map LogIndex ByteString)) |
  Tick Tock
  deriving (Eq)

newtype LogServiceChannel =
  LogServiceChannel (Unagi.InChan QueryApi, MVar (Maybe (Unagi.Element QueryApi, IO QueryApi), Unagi.OutChan QueryApi))

instance Comms QueryApi LogServiceChannel where
  initComms = LogServiceChannel <$> initCommsUnagi
  readComm (LogServiceChannel (_,o)) = readCommUnagi o
  readComms (LogServiceChannel (_,o)) = readCommsUnagi o
  writeComm (LogServiceChannel (i,_)) = writeCommUnagi i

data CryptoWorkerStatus =
  Unprocessed LogEntries |
  Processing |
  Idle
  deriving (Show, Eq)

data LogEnv = LogEnv
  { _logQueryChannel :: !LogServiceChannel
  , _internalEvent :: !InternalEventChannel
  , _commitChannel :: !CommitChannel
  , _evidence :: !EvidenceChannel
  , _keySet :: !KeySet
  , _cryptoWorkerTVar :: !(TVar CryptoWorkerStatus)
  , _debugPrint :: !(String -> IO ())
  , _dbConn :: !(Maybe Connection)
  , _publishMetric :: !(Metric -> IO ())}
makeLenses ''LogEnv

data LogState = LogState
  { _lsVolatileLogEntries  :: !LogEntries
  , _lsPersistedLogEntries :: !PersistedLogEntries
  , _lsLastApplied      :: !LogIndex
  , _lsLastLogIndex     :: !LogIndex
  , _lsLastLogHash      :: !ByteString
  , _lsNextLogIndex     :: !LogIndex
  , _lsCommitIndex      :: !LogIndex
  , _lsLastPersisted    :: !LogIndex
  , _lsLastInMemory     :: !(Maybe LogIndex)
  , _lsLastCryptoVerified :: !LogIndex
  , _lsLastLogTerm      :: !Term
  } deriving (Show, Eq, Generic)
makeLenses ''LogState

initLogState :: LogState
initLogState = LogState
  { _lsVolatileLogEntries = lesEmpty
  , _lsPersistedLogEntries = plesEmpty
  , _lsLastApplied = startIndex
  , _lsLastLogIndex = startIndex
  , _lsLastLogHash = mempty
  , _lsNextLogIndex = startIndex + 1
  , _lsCommitIndex = startIndex
  , _lsLastPersisted = startIndex
  , _lsLastInMemory = Nothing
  , _lsLastCryptoVerified = startIndex
  , _lsLastLogTerm = startTerm
  }

type LogThread = RWST LogEnv () LogState IO
