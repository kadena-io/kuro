
module Kadena.Types.Event
  ( Event(..)
  , Tock(..)
  , ResetLeaderNoFollowersTimeout(..)
  ) where

import Data.Thyme.Clock (UTCTime)

import Kadena.Types.Message

data Tock = Tock
  { _tockTargetDelay :: !Int
  , _tockStartTime :: !UTCTime
  } deriving (Show, Eq)

data ResetLeaderNoFollowersTimeout = ResetLeaderNoFollowersTimeout
  deriving Show

data Event = ERPC RPC
           | ElectionTimeout String
           | HeartbeatTimeout String
           | Tick Tock
  deriving (Show)
