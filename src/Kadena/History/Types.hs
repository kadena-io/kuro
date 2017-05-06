{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.History.Types
  ( History(..)
  , DbEnv(..)
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

import Data.HashMap.Strict (HashMap)
import Data.HashSet (HashSet)

import Data.Thyme.Clock (UTCTime)

import Database.SQLite3.Direct

import Kadena.Types.Base as X
import Kadena.Types.Config as X hiding (nodeId, _nodeId)
import Kadena.Types.Command as X
import Kadena.Types.Comms as X
import Kadena.Types.Metric as X
import Kadena.Types.Message as X
import Kadena.Types.Event (Beat)

newtype ExistenceResult = ExistenceResult
  { rksThatAlreadyExist :: HashSet RequestKey
  } deriving (Show, Eq)

newtype PossiblyIncompleteResults = PossiblyIncompleteResults
  { possiblyIncompleteResults :: HashMap RequestKey CommandResult
  } deriving (Show, Eq)

data ListenerResult =
  ListenerResult CommandResult |
  GCed String
  deriving (Show, Eq)

data History =
  AddNew
    { hNewKeys :: !(HashSet RequestKey) } |
  Update
    { hUpdateRks :: !(HashMap RequestKey CommandResult) } |
  QueryForExistence
    { hQueryForExistence :: !(HashSet RequestKey, MVar ExistenceResult) } |
  QueryForPriorApplication
    { hQueryForPriorApplication :: !(HashSet RequestKey, MVar ExistenceResult) } |
  QueryForResults
    { hQueryForResults :: !(HashSet RequestKey, MVar PossiblyIncompleteResults) } |
  RegisterListener
    { hNewListener :: !(HashMap RequestKey (MVar ListenerResult))} |
  PruneInFlightKeys
    { hKeysToPrune :: !(HashSet RequestKey) } |
  Bounce |
  Heart Beat
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


data DbEnv = DbEnv
  { _conn :: !Database
  , _insertStatement :: !Statement
  , _qryExistingStmt :: !Statement
  , _qryCompletedStmt :: !Statement
  }



data PersistenceSystem =
  InMemory
    { inMemResults :: !(HashMap RequestKey (Maybe CommandResult))} |
  OnDisk
    { incompleteRequestKeys :: !(HashSet RequestKey)
    , dbConn :: !DbEnv}

data HistoryState = HistoryState
  { _registeredListeners :: !(HashMap RequestKey [MVar ListenerResult])
  , _persistence :: !PersistenceSystem
  }
makeLenses ''HistoryState

type HistoryService = RWST HistoryEnv () HistoryState IO
