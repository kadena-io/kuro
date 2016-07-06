{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Juno.Types.Dispatch
  ( Dispatch(..), initDispatch
  , inboundAER
  , inboundCMD
  , inboundRVorRVR
  , inboundGeneral
  , outboundGeneral
  , outboundAerRvRvr
  , internalEvent
  , senderService
  , pprintTock
  , createTock
  , foreverTick
  , foreverTickDebugWriteDelay
  ) where

import Control.Lens
import Control.Monad
import Control.Concurrent (threadDelay)

import Data.Typeable
import Data.AffineSpace ((.-.))
import Data.Thyme.Clock (UTCTime, microseconds, getCurrentTime)

import Juno.Types.Comms
import Juno.Types.Event
import Juno.Types.Sender (SenderServiceChannel)
-- Tocks are useful for seeing how backed up things are
pprintTock :: Tock -> String -> IO String
pprintTock Tock{..} channelName = do
  t' <- getCurrentTime
  (delay :: Int) <- return $! (fromIntegral $ view microseconds $ t' .-. _tockStartTime)
  return $! "[" ++ channelName ++ "] Tock delayed by " ++ show delay ++ "mics"

createTock :: Int -> IO Tock
createTock delay = Tock <$> pure delay <*> getCurrentTime

fireTick :: (Comms a b) => b -> Int -> (Tock -> a) -> IO UTCTime
fireTick comm delay mkTock = do
  !t@(Tock _ st) <- createTock delay
  writeComm comm $ mkTock t
  return st

foreverTick :: Comms a b => b -> Int -> (Tock -> a) -> IO ()
foreverTick comm delay mkTock = forever $ do
  _ <- fireTick comm delay mkTock
  threadDelay delay

foreverTickDebugWriteDelay :: Comms a b => (String -> IO ()) -> String -> b -> Int -> (Tock -> a) -> IO ()
foreverTickDebugWriteDelay debug' channel comm delay mkTock = forever $ do
  !st <- fireTick comm delay mkTock
  !t' <- getCurrentTime
  !(writeDelay :: Int) <- return $! (fromIntegral $ view microseconds $ t' .-. st)
  debug' $ "[" ++ channel ++ "] writing Tock to channel took " ++ show writeDelay ++ "mics"
  threadDelay delay

data Dispatch = Dispatch
  { _inboundAER      :: InboundAERChannel
  , _inboundCMD      :: InboundCMDChannel
  , _inboundRVorRVR  :: InboundRVorRVRChannel
  , _inboundGeneral  :: InboundGeneralChannel
  , _outboundGeneral :: OutboundGeneralChannel
  , _outboundAerRvRvr :: OutboundAerRvRvrChannel
  , _internalEvent   :: InternalEventChannel
  , _senderService   :: SenderServiceChannel
  } deriving (Typeable)


initDispatch :: IO Dispatch
initDispatch = Dispatch
  <$> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms

makeLenses ''Dispatch
