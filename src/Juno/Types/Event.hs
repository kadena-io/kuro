{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Types.Event
  ( Event(..)
  , Tock(..)
  , ResetLeaderNoFollowersTimeout(..)
  ) where

import Data.Sequence as Seq
import Data.Thyme.Clock (UTCTime)

import Juno.Types.Base
import Juno.Types.Message
import Juno.Types.Log (LogEntry)

data Tock = Tock {_tockTargetDelay :: Int, _tockStartTime :: UTCTime}
  deriving (Show, Eq)

data ResetLeaderNoFollowersTimeout = ResetLeaderNoFollowersTimeout deriving (Show)

data Event = ERPC RPC
           | ElectionTimeout String
           | HeartbeatTimeout String
           | ApplyLogEntries (Maybe (Seq LogEntry)) LogIndex
           | Tick Tock
  deriving (Show)
