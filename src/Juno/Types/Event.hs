{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Types.Event
  ( Event(..)
  , Tock(..)
  , ResetLeaderNoFollowersTimeout(..)
  ) where

import Data.Thyme.Clock (UTCTime)

import Juno.Types.Message

data Tock = Tock {_tockTargetDelay :: Int, _tockStartTime :: UTCTime}
  deriving (Show, Eq)

data ResetLeaderNoFollowersTimeout = ResetLeaderNoFollowersTimeout deriving (Show)

data Event = ERPC RPC
           | ElectionTimeout String
           | HeartbeatTimeout String
           | ApplyLogEntries
           | Tick Tock
  deriving (Show)
