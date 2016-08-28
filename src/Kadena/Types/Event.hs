{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Types.Event
  ( Event(..)
  , Tock(..)
  , ResetLeaderNoFollowersTimeout(..)
  ) where

import Data.Thyme.Clock (UTCTime)

import Kadena.Types.Message
import Kadena.Types.Log (LogEntries)

data Tock = Tock {_tockTargetDelay :: Int, _tockStartTime :: UTCTime}
  deriving (Show, Eq)

data ResetLeaderNoFollowersTimeout = ResetLeaderNoFollowersTimeout deriving (Show)

data Event = ERPC RPC
           | ElectionTimeout String
           | HeartbeatTimeout String
           | ApplyLogEntries LogEntries
           | Tick Tock
  deriving (Show)
