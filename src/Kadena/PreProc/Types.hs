{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.PreProc.Types
  ( ProcessRequest(..)
  , ProcessRequestEnv(..)
  , processRequestChannel, debugPrint, getTimestamp, threadCount, usePar
  , ProcessRequestChannel(..)
  , ProcessRequestService
  , module X
  ) where

import Control.Lens hiding (Index)

import Control.Monad.Trans.Reader
import Control.Concurrent.Chan (Chan)
import Control.Concurrent.STM

import Data.Sequence (Seq)
import Data.Thyme.Clock (UTCTime)

import Kadena.Types.Command as X
import Kadena.Types.Comms as X

data ProcessRequest =
  CommandPreProc
  { _cmdPreProc :: !RunPreProc } |
  Heart Beat

newtype ProcessRequestChannel = ProcessRequestChannel (Chan ProcessRequest, TVar (Seq ProcessRequest))

instance Comms ProcessRequest ProcessRequestChannel where
  initComms = ProcessRequestChannel <$> initCommsBatched
  readComm (ProcessRequestChannel (_,m)) = readCommBatched m
  writeComm (ProcessRequestChannel (c,_)) = writeCommBatched c
  {-# INLINE initComms #-}
  {-# INLINE readComm #-}
  {-# INLINE writeComm #-}

instance BatchedComms ProcessRequest ProcessRequestChannel where
  readComms (ProcessRequestChannel (_,m)) cnt = readCommsBatched m cnt
  {-# INLINE readComms #-}
  writeComms (ProcessRequestChannel (_,m)) xs = writeCommsBatched m xs
  {-# INLINE writeComms #-}

data ProcessRequestEnv = ProcessRequestEnv
  { _processRequestChannel :: !ProcessRequestChannel
  , _threadCount :: !Int
  , _debugPrint :: !(String -> IO ())
  , _getTimestamp :: !(IO UTCTime)
  , _usePar :: !Bool
  }
makeLenses ''ProcessRequestEnv

type ProcessRequestService = ReaderT ProcessRequestEnv IO
