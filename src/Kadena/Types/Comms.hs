{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Kadena.Types.Comms
  ( Comms(..)
  , BatchedComms(..)
  , InboundAER(..)
  , InboundAERChannel(..)
  , InboundRVorRVR(..)
  , InboundRVorRVRChannel(..)
  , InboundGeneral(..)
  , InboundGeneralChannel(..)
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
  , writeCommsBatched
  ) where

import Control.Monad
import qualified Control.Concurrent.Async as Async
import Control.Concurrent.STM (atomically, retry)
import Control.Concurrent.STM.TVar
import Control.Concurrent.Chan
import Control.Concurrent.BoundedChan (BoundedChan)
import qualified Control.Concurrent.BoundedChan as BoundedChan

import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Typeable


import Kadena.Types.Base
-- import Kadena.Types.Event
import Kadena.Types.Message.Signed
-- import Kadena.Types.Message


newtype InboundAER = InboundAER { _unInboundAER :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

newtype InboundGeneral = InboundGeneral { _unInboundGeneral :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

newtype InboundRVorRVR = InboundRVorRVR { _unInboundRVorRVR :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)


newtype InboundAERChannel = InboundAERChannel (Chan InboundAER, TVar (Seq InboundAER))
newtype InboundRVorRVRChannel = InboundRVorRVRChannel (Chan InboundRVorRVR)
newtype InboundGeneralChannel = InboundGeneralChannel (Chan InboundGeneral, TVar (Seq InboundGeneral))

class Comms f c | c -> f where
  initComms :: IO c
  readComm :: c -> IO f
  writeComm :: c -> f -> IO ()

class (Comms f c) => BatchedComms f c | c -> f where
  readComms :: c -> Int -> IO (Seq f)
  writeComms :: c -> [f] -> IO ()

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
  writeComms (InboundAERChannel (_,m)) xs = writeCommsBatched m xs
  {-# INLINE writeComms #-}

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
  writeComms (InboundGeneralChannel (_,m)) xs = writeCommsBatched m xs
  {-# INLINE writeComms #-}

instance Comms InboundRVorRVR InboundRVorRVRChannel where
  initComms = InboundRVorRVRChannel <$> initCommsNormal
  readComm (InboundRVorRVRChannel c) = readCommNormal c
  writeComm (InboundRVorRVRChannel c) = writeCommNormal c
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

writeCommsBatched :: TVar (Seq a) -> [a] -> IO ()
writeCommsBatched tv xs = do
  asSeq <- return $! Seq.fromList xs
  atomically $ modifyTVar' tv (\s -> s Seq.>< asSeq)
{-# INLINE writeCommsBatched #-}
