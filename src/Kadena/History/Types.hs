{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.History.Types
  ( History(..)
  , ExistenceResult(..)
  , PossiblyIncompleteResults(..)
  , ListenerResult(..)
  , HistoryEnv(..)
  , historyChannel, debugPrint, getTimestamp, dbPath
  , HistoryState(..)
  , registeredListeners, persistence
  , PersistenceSystem(..)
  , HistoryChannel(..)
  , HistoryService
  , module X
  ) where

import Control.Lens hiding (Index)

import Control.Monad.Trans.RWS.Strict
import Control.Concurrent.MVar
import Control.Concurrent.Chan (Chan)

import Data.Map.Strict (Map)
import Data.Set (Set)

import Data.Thyme.Clock (UTCTime)
import Database.SQLite.Simple (Connection(..))

import Kadena.Types.Base as X
import Kadena.Types.Config as X hiding (nodeId, _nodeId)
import Kadena.Types.Command as X
import Kadena.Types.Comms as X
import Kadena.Types.Metric as X
import Kadena.Types.Message as X

newtype ExistenceResult = ExistenceResult
  { rksThatAlreadyExist :: Set RequestKey
  } deriving (Show, Eq)

newtype PossiblyIncompleteResults = PossiblyIncompleteResults
  { possiblyIncompleteResults :: Map RequestKey CommandResult
  } deriving (Show, Eq)

data ListenerResult =
  ListenerResult CommandResult |
  GCed
  deriving (Show, Eq)

data History =
  AddNew
    { hNewKeys :: !(Set RequestKey) } |
  Update
    { hUpdateRks :: !(Map RequestKey CommandResult) } |
  QueryForExistence
    { hQueryForExistence :: !(Set RequestKey, MVar ExistenceResult) } |
  QueryForResults
    { hQueryForResults :: !(RequestKey, MVar PossiblyIncompleteResults) } |
  RegisterListener
    { hNewListener :: !(RequestKey, MVar ListenerResult)} |
  Bounce |
  Tick Tock
  deriving (Eq)

newtype HistoryChannel = HistoryChannel (Chan History)

instance Comms History HistoryChannel where
  initComms = HistoryChannel <$> initCommsNormal
  readComm (HistoryChannel c) = readCommNormal c
  writeComm (HistoryChannel c) = writeCommNormal c

data HistoryEnv = HistoryEnv
  { _historyChannel :: !HistoryChannel
  , _debugPrint :: !(String -> IO ())
  , _getTimestamp :: !(IO UTCTime)
  , _dbPath :: !(Maybe FilePath)
  }
makeLenses ''HistoryEnv

data PersistenceSystem =
  InMemory
    {inMemResults :: !(Map RequestKey (Maybe CommandResult))} |
  OnDisk
    {dbConn :: !Connection}

data HistoryState = HistoryState
  { _registeredListeners :: !(Map RequestKey [MVar ListenerResult])
  , _persistence :: !PersistenceSystem
  }
makeLenses ''HistoryState

type HistoryService = RWST HistoryEnv () HistoryState IO
