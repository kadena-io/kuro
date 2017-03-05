
module Kadena.Types.Event
  ( Event(..)
  , Beat(..)
  , ResetLeaderNoFollowersTimeout(..)
  ) where

import Data.Thyme.Clock (UTCTime)

import Kadena.Types.Command
import Kadena.Types.Message

data Beat = Beat
  { _tockTargetDelay :: !Int
  , _tockStartTime :: !UTCTime
  } deriving (Show, Eq)

data ResetLeaderNoFollowersTimeout = ResetLeaderNoFollowersTimeout
  deriving Show

data Event = ERPC RPC
           | NewCmd [Command] -- [(ReceivedAt, Command)]
           | ElectionTimeout String
           | HeartbeatTimeout String
           | Heart Beat
  deriving (Show)
