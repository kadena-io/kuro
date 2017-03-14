{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.PreProc.Types
  ( ProcessRequest(..)
  , ProcessRequestEnv(..)
  , processRequestChannel, debugPrint, getTimestamp, threadCount
  , ProcessRequestChannel(..)
  , ProcessRequestService
  , module X
  ) where

import Control.Lens hiding (Index)

import Control.Monad.Trans.Reader
import Control.Concurrent.Chan (Chan)

import Data.Thyme.Clock (UTCTime)

import Kadena.Types.Command as X
import Kadena.Types.Comms as X

data ProcessRequest =
  CommandPreProc
  { _cmdPreProc :: !RunPreProc } |
  Heart Beat

newtype ProcessRequestChannel = ProcessRequestChannel (Chan ProcessRequest)

instance Comms ProcessRequest ProcessRequestChannel where
  initComms = ProcessRequestChannel <$> initCommsNormal
  readComm (ProcessRequestChannel c) = readCommNormal c
  writeComm (ProcessRequestChannel c) = writeCommNormal c

data ProcessRequestEnv = ProcessRequestEnv
  { _processRequestChannel :: !ProcessRequestChannel
  , _threadCount :: !Int
  , _debugPrint :: !(String -> IO ())
  , _getTimestamp :: !(IO UTCTime)
  }
makeLenses ''ProcessRequestEnv

type ProcessRequestService = ReaderT ProcessRequestEnv IO
