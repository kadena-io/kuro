{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.Types.History
  ( History(..)
  , DbEnv(..)
  , ExistenceResult(..)
  , PossiblyIncompleteResults(..)
  , ListenerResult(..)
  , HistoryEnv(..)
  , henvHistoryChannel, henvDebugPrint, henvGetTimestamp, henvDbPath, henvConfig
  , HistoryState(..)
  , registeredListeners, persistence
  , PersistenceSystem(..)
  , HistoryChannel(..)
  , HistoryService
  ) where

import Control.Lens hiding (Index)

import Control.Monad.Trans.RWS.Strict
import Control.Concurrent.MVar
import Control.Concurrent.Chan (Chan)

import Data.HashMap.Strict (HashMap)
import Data.HashSet (HashSet)

import Data.Thyme.Clock (UTCTime)

import Database.SQLite3.Direct

import Kadena.Config.TMVar as Cfg
import Kadena.Types.Base
import Kadena.Types.Command
import Kadena.Types.Comms
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
  HistoryBeat Beat
  deriving (Eq)

newtype HistoryChannel = HistoryChannel (Chan History)

instance Comms History HistoryChannel where
  initComms = HistoryChannel <$> initCommsNormal
  readComm (HistoryChannel c) = readCommNormal c
  writeComm (HistoryChannel c) = writeCommNormal c

data HistoryEnv = HistoryEnv
  { _henvHistoryChannel :: !HistoryChannel
  , _henvDebugPrint :: !(String -> IO ())
  , _henvGetTimestamp :: !(IO UTCTime)
  , _henvDbPath :: !(Maybe FilePath)
  , _henvConfig :: !Cfg.GlobalConfigTMVar
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
