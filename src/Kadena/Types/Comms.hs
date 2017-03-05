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

module Kadena.Types.Comms
  -- Hearts are useful
  ( Beat(..)
  , pprintBeat
  , createBeat
  , foreverHeart
  , foreverHeartDebugWriteDelay
  -- Comm Channels
  , Comms(..)
  , BatchedComms(..)
  , InboundAER(..)
  , InboundAERChannel(..)
  , InboundCMD(..)
  , InboundRVorRVR(..)
  , InboundCMDChannel(..)
  , InboundRVorRVRChannel(..)
  , InboundGeneral(..)
  , InboundGeneralChannel(..)
  , OutboundGeneral(..)
  , OutboundGeneralChannel(..)
  , broadcastMsg, directMsg
  , OutboundAerRvRvr(..)
  , OutboundAerRvRvrChannel(..)
  , aerRvRvrMsg
  , InternalEvent(..)
  , InternalEventChannel(..)
  -- for construction of chans elsewhere
  , initCommsNormal
  , readCommNormal
  , writeCommNormal
  , initCommsBounded
  , readCommBounded
  , writeCommBounded
  , initCommsBatched
  , readCommBatched
  , readCommsBatched
  , writeCommBatched
  ) where

import Control.Monad
import Control.Lens
import qualified Control.Concurrent.Async as Async
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, retry)
import Control.Concurrent.STM.TVar
import Control.Concurrent.Chan
import Control.Concurrent.BoundedChan (BoundedChan)
import qualified Control.Concurrent.BoundedChan as BoundedChan

import Data.ByteString (ByteString)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Typeable

import Data.AffineSpace ((.-.))
import Data.Thyme.Clock (UTCTime, microseconds, getCurrentTime)

import Kadena.Types.Base
import Kadena.Types.Event
import Kadena.Types.Message.Signed
import Kadena.Types.Message

-- Beats are useful for seeing how backed up things are
pprintBeat :: Beat -> IO String
pprintBeat Beat{..} = do
  t' <- getCurrentTime
  (delay :: Int) <- return $! (fromIntegral $ view microseconds $ t' .-. _tockStartTime)
  return $! "Heartbeat delayed by " ++ show delay ++ "mics"

createBeat :: Int -> IO Beat
createBeat delay = Beat <$> pure delay <*> getCurrentTime

fireHeart :: (Comms a b) => b -> Int -> (Beat -> a) -> IO UTCTime
fireHeart comm delay mkBeat = do
  !t@(Beat _ st) <- createBeat delay
  writeComm comm $ mkBeat t
  return st

foreverHeart :: Comms a b => b -> Int -> (Beat -> a) -> IO ()
foreverHeart comm delay mkBeat = forever $ do
  _ <- fireHeart comm delay mkBeat
  threadDelay delay

foreverHeartDebugWriteDelay :: Comms a b => (String -> IO ()) -> b -> Int -> (Beat -> a) -> IO ()
foreverHeartDebugWriteDelay debug' comm delay mkBeat = forever $ do
  !st <- fireHeart comm delay mkBeat
  !t' <- getCurrentTime
  !(writeDelay :: Int) <- return $! (fromIntegral $ view microseconds $ t' .-. st)
  debug' $ "writing heartbeat to channel took " ++ show writeDelay ++ "mics"
  threadDelay delay

newtype InboundAER = InboundAER { _unInboundAER :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

data InboundCMD =
  InboundCMD
  { _unInboundCMD :: (ReceivedAt, SignedRPC)} |
  InboundCMDFromApi
  { _unInboundCMDFromApi :: (ReceivedAt, NewCmdInternal)}
  deriving (Show, Eq, Typeable)

newtype InboundGeneral = InboundGeneral { _unInboundGeneral :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

newtype InboundRVorRVR = InboundRVorRVR { _unInboundRVorRVR :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

newtype OutboundGeneral = OutboundGeneral { _unOutboundGeneral :: [Envelope]}
  deriving (Show, Eq, Typeable)

newtype OutboundAerRvRvr = OutboundAerRvRvr { _unOutboundAerRvRvr :: [Envelope]}
  deriving (Show, Eq, Typeable)

directMsg :: [(NodeId, ByteString)] -> OutboundGeneral
directMsg msgs = OutboundGeneral $! Envelope . (\(n,b) -> (Topic $ unAlias $ _alias n, b)) <$> msgs

broadcastMsg :: [ByteString] -> OutboundGeneral
broadcastMsg msgs = OutboundGeneral $! Envelope . (\b -> (Topic $ "all", b)) <$> msgs

aerRvRvrMsg :: [ByteString] -> OutboundAerRvRvr
aerRvRvrMsg msgs = OutboundAerRvRvr $! Envelope . (\b -> (Topic $ "all", b)) <$> msgs

newtype InternalEvent = InternalEvent { _unInternalEvent :: Event}
  deriving (Show, Typeable)

newtype InboundAERChannel = InboundAERChannel (Chan InboundAER, TVar (Seq InboundAER))
newtype InboundCMDChannel = InboundCMDChannel (Chan InboundCMD, TVar (Seq InboundCMD))
newtype InboundRVorRVRChannel = InboundRVorRVRChannel (Chan InboundRVorRVR)
newtype InboundGeneralChannel = InboundGeneralChannel (Chan InboundGeneral, TVar (Seq InboundGeneral))
newtype OutboundGeneralChannel = OutboundGeneralChannel (Chan OutboundGeneral)
newtype OutboundAerRvRvrChannel = OutboundAerRvRvrChannel (Chan OutboundAerRvRvr)
newtype InternalEventChannel = InternalEventChannel (BoundedChan InternalEvent)

class Comms f c | c -> f where
  initComms :: IO c
  readComm :: c -> IO f
  writeComm :: c -> f -> IO ()

class (Comms f c) => BatchedComms f c | c -> f where
  readComms :: c -> Int -> IO (Seq f)

instance Comms InboundAER InboundAERChannel where
  initComms = InboundAERChannel <$> initCommsBatched
  readComm (InboundAERChannel (_,m)) = readCommBatched m
  writeComm (InboundAERChannel (c,_)) = writeCommBatched c
  {-# INLINE initComms #-}
  {-# INLINE readComm #-}
  {-# INLINE writeComm #-}

instance BatchedComms InboundAER InboundAERChannel where
  readComms (InboundAERChannel (_,m)) cnt = readCommsBatched m cnt
  {-# INLINE readComms #-}

instance Comms InboundCMD InboundCMDChannel where
  initComms = InboundCMDChannel <$> initCommsBatched
  readComm (InboundCMDChannel (_,m))  = readCommBatched m
  writeComm (InboundCMDChannel (c,_)) = writeCommBatched c
  {-# INLINE initComms #-}
  {-# INLINE readComm #-}
  {-# INLINE writeComm #-}

instance BatchedComms InboundCMD InboundCMDChannel where
  readComms (InboundCMDChannel (_,m)) cnt = readCommsBatched m cnt
  {-# INLINE readComms #-}

instance Comms InboundGeneral InboundGeneralChannel where
  initComms = InboundGeneralChannel <$> initCommsBatched
  readComm (InboundGeneralChannel (_,m))  = readCommBatched m
  writeComm (InboundGeneralChannel (c,_)) = writeCommBatched c
  {-# INLINE initComms #-}
  {-# INLINE readComm #-}
  {-# INLINE writeComm #-}

instance BatchedComms InboundGeneral InboundGeneralChannel where
  readComms (InboundGeneralChannel (_,m)) cnt = readCommsBatched m cnt
  {-# INLINE readComms #-}

instance Comms InboundRVorRVR InboundRVorRVRChannel where
  initComms = InboundRVorRVRChannel <$> initCommsNormal
  readComm (InboundRVorRVRChannel c) = readCommNormal c
  writeComm (InboundRVorRVRChannel c) = writeCommNormal c
  {-# INLINE initComms #-}
  {-# INLINE readComm #-}
  {-# INLINE writeComm #-}

instance Comms OutboundGeneral OutboundGeneralChannel where
  initComms = OutboundGeneralChannel <$> initCommsNormal
  readComm (OutboundGeneralChannel c) = readCommNormal c
  writeComm (OutboundGeneralChannel c) = writeCommNormal c
  {-# INLINE initComms #-}
  {-# INLINE readComm #-}
  {-# INLINE writeComm #-}

instance Comms OutboundAerRvRvr OutboundAerRvRvrChannel where
  initComms = OutboundAerRvRvrChannel <$> initCommsNormal
  readComm (OutboundAerRvRvrChannel c) = readCommNormal c
  writeComm (OutboundAerRvRvrChannel c) = writeCommNormal c
  {-# INLINE initComms #-}
  {-# INLINE readComm #-}
  {-# INLINE writeComm #-}

instance Comms InternalEvent InternalEventChannel where
  initComms = InternalEventChannel <$> initCommsBounded
  readComm (InternalEventChannel c) = readCommBounded c
  writeComm (InternalEventChannel c) = writeCommBounded c
  {-# INLINE initComms #-}
  {-# INLINE readComm #-}
  {-# INLINE writeComm #-}

{-# INLINE initCommsNormal #-}
initCommsNormal :: IO (Chan a)
initCommsNormal = newChan

{-# INLINE readCommNormal #-}
readCommNormal :: Chan a -> IO a
readCommNormal c = readChan c

{-# INLINE writeCommNormal #-}
writeCommNormal :: Chan a -> a -> IO ()
writeCommNormal c m = writeChan c m

{-# INLINE initCommsBounded #-}
initCommsBounded :: IO (BoundedChan a)
initCommsBounded = BoundedChan.newBoundedChan 20

{-# INLINE readCommBounded #-}
readCommBounded :: BoundedChan a -> IO a
readCommBounded c = BoundedChan.readChan c

{-# INLINE writeCommBounded #-}
writeCommBounded :: BoundedChan a -> a -> IO ()
writeCommBounded c m = BoundedChan.writeChan c m

{-# INLINE initCommsBatched #-}
initCommsBatched :: IO (Chan a, TVar (Seq a))
initCommsBatched = do
  c <- newChan
  s <- newTVarIO $ Seq.empty
  Async.link =<< Async.async (readAndAddToSeq c s)
  return (c,s)

{-# INLINE readAndAddToSeq #-}
readAndAddToSeq :: Chan a -> TVar (Seq a) -> IO ()
readAndAddToSeq c ms = forever $ do
  m <- readChan c
  atomically $ modifyTVar' ms (\s -> s Seq.|> m )

{-# INLINE readCommBatched #-}
readCommBatched :: TVar (Seq a) -> IO a
readCommBatched ms = atomically $ do
  s <- readTVar ms
  case Seq.viewl s of
    Seq.EmptyL -> retry
    a Seq.:< as -> writeTVar ms as >> return a

{-# INLINE readCommsBatched #-}
readCommsBatched :: TVar (Seq a) -> Int -> IO (Seq a)
readCommsBatched ms cnt = atomically $ do
  s <- readTVar ms
  if Seq.null s
  then retry
  else if Seq.length s <= cnt
       then do
        writeTVar ms $! Seq.empty
        return $! s
       else do
        (res, rest) <- return $! Seq.splitAt cnt s
        writeTVar ms rest
        return $! res

{-# INLINE writeCommBatched #-}
writeCommBatched :: Chan a -> a -> IO ()
writeCommBatched c a = writeChan c a
