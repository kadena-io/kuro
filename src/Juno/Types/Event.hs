{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Types.Event
  ( Event(..)
  , Tock(..)
  ) where

import Data.Thyme.Clock (UTCTime)

import Juno.Types.Message

data Tock = Tock {_tockTargetDelay :: Int, _tockStartTime :: UTCTime}
  deriving (Show, Eq)

data Event = ERPC RPC
           | AERs AlotOfAERs
           | ElectionTimeout String
           | HeartbeatTimeout String
           | Tick Tock
  deriving (Show)
