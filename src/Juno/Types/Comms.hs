{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Juno.Types.Comms
  ( Comms(..)
  , Dispatch(..), inboundAER, inboundCMD, inboundRVorRVR, inboundGeneral, outboundGeneral, internalEvent
  , initDispatch
  , InboundAER(..)
  , InboundCMD(..)
  , InboundRVorRVR(..)
  , InboundGeneral(..)
  , OutboundGeneral(..)
  , InternalEvent(..)
  , InChan
  , OutChan
  , CommChannel(..)
  ) where

import Juno.Types.Base
import Juno.Types.Event
import Juno.Types.Message.Signed
import Juno.Types.Message

import Control.Lens
import Control.Monad
import Control.Concurrent (threadDelay, takeMVar, putMVar, newMVar, MVar)

import qualified Control.Concurrent.Chan.Unagi.Bounded as Bounded
import qualified Control.Concurrent.Chan.Unagi as Unagi
import qualified Control.Concurrent.Chan.Unagi.NoBlocking as NoBlock

import Data.ByteString hiding (head)
import Data.Typeable

newtype InboundAER = InboundAER { _unInboundAER :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

newtype InboundCMD = InboundCMD { _unInboundCMD :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

newtype InboundGeneral = InboundGeneral { _unInboundGeneral :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

newtype InboundRVorRVR = InboundRVorRVR { _unInboundRVorRVR :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

newtype OutboundGeneral = OutboundGeneral { _unOutboundGeneral :: OutBoundMsg String ByteString}
  deriving (Show, Eq, Typeable)

newtype InternalEvent = InternalEvent { _unInternalEvent :: Event}
  deriving (Show, Typeable)

type family InChan c where
  InChan InboundAER = NoBlock.InChan InboundAER
  InChan InboundCMD = NoBlock.InChan InboundCMD
  InChan InboundRVorRVR = Unagi.InChan InboundRVorRVR
  InChan InboundGeneral = NoBlock.InChan InboundGeneral
  InChan OutboundGeneral = Unagi.InChan OutboundGeneral
  InChan InternalEvent = Bounded.InChan InternalEvent

type family OutChan c where
  OutChan InboundAER = MVar (NoBlock.Stream InboundAER)
  OutChan InboundCMD = MVar (NoBlock.Stream InboundCMD)
  OutChan InboundRVorRVR = MVar (Maybe (Unagi.Element InboundRVorRVR, IO InboundRVorRVR), Unagi.OutChan InboundRVorRVR)
  OutChan InboundGeneral = MVar (NoBlock.Stream InboundGeneral)
  OutChan OutboundGeneral = MVar (Maybe (Unagi.Element OutboundGeneral, IO OutboundGeneral), Unagi.OutChan OutboundGeneral)
  OutChan InternalEvent = MVar (Maybe (Bounded.Element InternalEvent, IO InternalEvent), Bounded.OutChan InternalEvent)

class Comms c where
  data CommChannel c :: *
  inChan :: CommChannel c -> InChan c
  outChan :: CommChannel c -> OutChan c
  initComms :: IO (CommChannel c)
  readComm :: OutChan c -> IO c
  readComms :: OutChan c -> Int -> IO [c]
  writeComm :: InChan c -> c -> IO ()

instance Comms InboundAER where
  data CommChannel InboundAER = InboundAERCC (InChan InboundAER, OutChan InboundAER)
  inChan (InboundAERCC (i,_)) = i
  outChan (InboundAERCC (_,m)) = m
  initComms = InboundAERCC <$> initCommsNoBlock
  readComm = readCommNoBlock
  readComms = readCommsNoBlock
  writeComm = writeCommNoBlock

instance Comms InboundCMD where
  data CommChannel InboundCMD = InboundCMDCC (InChan InboundCMD, OutChan InboundCMD)
  inChan (InboundCMDCC (i,_)) = i
  outChan (InboundCMDCC (_,m)) = m
  initComms = InboundCMDCC <$> initCommsNoBlock
  readComm = readCommNoBlock
  readComms = readCommsNoBlock
  writeComm = writeCommNoBlock

instance Comms InboundGeneral where
  data CommChannel InboundGeneral = InboundGeneralCC (InChan InboundGeneral, OutChan InboundGeneral)
  inChan (InboundGeneralCC (i,_)) = i
  outChan (InboundGeneralCC (_,m)) = m
  initComms = InboundGeneralCC <$> initCommsNoBlock
  readComm = readCommNoBlock
  readComms = readCommsNoBlock
  writeComm = writeCommNoBlock

instance Comms InboundRVorRVR where
  data CommChannel InboundRVorRVR = InboundRVorRVRCC (InChan InboundRVorRVR, OutChan InboundRVorRVR)
  inChan (InboundRVorRVRCC (i,_)) = i
  outChan (InboundRVorRVRCC (_,m)) = m
  initComms = InboundRVorRVRCC <$> initCommsUnagi
  readComm = readCommUnagi
  readComms = readCommsUnagi
  writeComm = writeCommUnagi

instance Comms OutboundGeneral where
  data CommChannel OutboundGeneral = OutboundGeneralCC (InChan OutboundGeneral, OutChan OutboundGeneral)
  inChan (OutboundGeneralCC (i,_)) = i
  outChan (OutboundGeneralCC (_,m)) = m
  initComms = OutboundGeneralCC <$> initCommsUnagi
  readComm = readCommUnagi
  readComms = readCommsUnagi
  writeComm = writeCommUnagi

instance Comms InternalEvent where
  data CommChannel InternalEvent = InternalEventCC (InChan InternalEvent, OutChan InternalEvent)
  inChan (InternalEventCC (i,_)) = i
  outChan (InternalEventCC (_,m)) = m
  initComms = InternalEventCC <$> initCommsBounded
  readComm = readCommBounded
  readComms = readCommsBounded
  writeComm = writeCommBounded

data Dispatch = Dispatch
  { _inboundAER      :: CommChannel InboundAER
  , _inboundCMD      :: CommChannel InboundCMD
  , _inboundRVorRVR  :: CommChannel InboundRVorRVR
  , _inboundGeneral  :: CommChannel InboundGeneral
  , _outboundGeneral :: CommChannel OutboundGeneral
  , _internalEvent   :: CommChannel InternalEvent
  } deriving (Typeable)


initDispatch :: IO Dispatch
initDispatch = Dispatch
  <$> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms

-- Implementations for each type of chan that we use
initCommsBounded :: IO (Bounded.InChan a, MVar (Maybe a1, Bounded.OutChan a))
initCommsBounded = do
  (i, o) <- Bounded.newChan 20
  m <- newMVar (Nothing, o)
  return (i,m)

readCommBounded :: MVar (Maybe (t, IO b), Bounded.OutChan b) -> IO b
readCommBounded m = do
  (e, o) <- takeMVar m
  case e of
    Nothing -> do
      r <- Bounded.readChan o
      putMVar m (Nothing, o)
      return r
    Just (_,blockingRead) -> do
      putMVar m (Nothing,o) >> blockingRead

readCommsBounded
  :: (Num a1, Ord a1)
  =>  MVar (Maybe (NoBlock.Element a, IO a), Bounded.OutChan a)
  -> a1
  -> IO [a]
readCommsBounded m cnt = do
  (e, o) <- takeMVar m
  case e of
    Nothing -> do
      readBoundedUnagi Nothing m o cnt
    Just (v,blockingRead) -> do
      r <- Bounded.tryRead v
      case r of
        Nothing -> putMVar m (Just (v,blockingRead),o) >> return []
        Just v' -> readBoundedUnagi (Just v') m o cnt

writeCommBounded :: Bounded.InChan a -> a -> IO ()
writeCommBounded i c = Bounded.writeChan i c

initCommsNoBlock :: IO (NoBlock.InChan a, MVar (NoBlock.Stream a))
initCommsNoBlock = do
    (i, o) <- NoBlock.newChan
    m <- newMVar =<< return . head =<< NoBlock.streamChan 1 o
    return (i,m)

readCommNoBlock :: MVar (NoBlock.Stream b) -> IO b
readCommNoBlock m = do
    possibleRead <- takeMVar m
    t <- NoBlock.tryReadNext possibleRead
    case t of
      NoBlock.Pending -> putMVar m possibleRead >> readCommNoBlock m
      NoBlock.Next v possibleRead' -> putMVar m possibleRead' >> return v

readCommsNoBlock :: (Eq t, Num a, Ord a) => MVar (NoBlock.Stream t) -> a -> IO [t]
readCommsNoBlock m cnt = do
    possibleRead <- takeMVar m
    blog <- readStream m possibleRead cnt
    if blog /= []
      then return blog
      else threadDelay 1000 >> return []

writeCommNoBlock :: NoBlock.InChan a -> a -> IO ()
writeCommNoBlock i c = NoBlock.writeChan i c

initCommsUnagi :: IO (Unagi.InChan a, MVar (Maybe a1, Unagi.OutChan a))
initCommsUnagi = do
  (i, o) <- Unagi.newChan
  m <- newMVar (Nothing, o)
  return (i,m)

readCommUnagi :: MVar (Maybe (t, IO b), Unagi.OutChan b) -> IO b
readCommUnagi m = do
  (e, o) <- takeMVar m
  case e of
    Nothing -> do
      r <- Unagi.readChan o
      putMVar m (Nothing, o)
      return r
    Just (_,blockingRead) -> do
      putMVar m (Nothing,o) >> blockingRead

readCommsUnagi
  :: (Num a1, Ord a1)
  => MVar (Maybe (NoBlock.Element a, IO a), Unagi.OutChan a)
  -> a1
  -> IO [a]
readCommsUnagi m cnt = do
  (e, o) <- takeMVar m
  case e of
    Nothing -> do
      readRegularUnagi Nothing m o cnt
    Just (v,blockingRead) -> do
      r <- Unagi.tryRead v
      case r of
        Nothing -> putMVar m (Just (v,blockingRead),o) >> return []
        Just v' -> readRegularUnagi (Just v') m o cnt

writeCommUnagi :: Unagi.InChan a -> a -> IO ()
writeCommUnagi i c = Unagi.writeChan i c

-- Utility Functions to allow for reading N elements off a queue
readRegularUnagi :: (Num a, Ord a)
                 => Maybe t
                 -> MVar (Maybe (Unagi.Element t, IO t), Unagi.OutChan t)
                 -> Unagi.OutChan t
                 -> a
                 -> IO [t]
readRegularUnagi (Just t) m o cnt' = liftM (t:) (readRegularUnagi Nothing m o (cnt'-1))
readRegularUnagi Nothing m o cnt'
  | cnt' <= 0 = putMVar m (Nothing, o) >> return []
  | otherwise = do
      (r,blockingRead) <- Unagi.tryReadChan o
      r' <- Unagi.tryRead r
      case r' of
        Nothing -> putMVar m (Just (r,blockingRead), o) >> return []
        Just v -> liftM (v:) (readRegularUnagi Nothing m o (cnt'-1))

readBoundedUnagi :: (Num a, Ord a)
                 =>  Maybe t
                 -> MVar (Maybe (Bounded.Element t, IO t), Bounded.OutChan t)
                 -> Bounded.OutChan t
                 -> a
                 -> IO [t]
readBoundedUnagi (Just t) m o cnt' = liftM (t:) (readBoundedUnagi Nothing m o (cnt'-1))
readBoundedUnagi Nothing m o cnt'
  | cnt' <= 0 = putMVar m (Nothing, o) >> return []
  | otherwise = do
      (r,blockingRead) <- Bounded.tryReadChan o
      r' <- Bounded.tryRead r
      case r' of
        Nothing -> putMVar m (Just (r,blockingRead), o) >> return []
        Just v -> liftM (v:) (readBoundedUnagi Nothing m o (cnt'-1))

readStream :: (Num a, Ord a)
           =>  MVar (NoBlock.Stream t)
           -> NoBlock.Stream t
           -> a
           -> IO [t]
readStream m strm cnt'
  | cnt' <= 0 = putMVar m strm >> return []
  | otherwise = do
      s <- NoBlock.tryReadNext strm
      case s of
        NoBlock.Next a strm' -> liftM (a:) (readStream m strm' (cnt'-1))
        NoBlock.Pending -> putMVar m strm >> return []

makeLenses ''Dispatch
