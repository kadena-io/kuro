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

module Juno.Types.Comms
  -- Ticks are useful
  ( Tock(..)
  , pprintTock
  , createTock
  , foreverTick
  , foreverTickDebugWriteDelay
  -- Comm Channels
  , Comms(..)
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
  , initCommsBounded
  , initCommsNoBlock
  , initCommsUnagi
  , readCommBounded
  , readCommNoBlock
  , readCommUnagi
  , readCommsBounded
  , readCommsNoBlock
  , readCommsUnagi
  , writeCommBounded
  , writeCommNoBlock
  , writeCommUnagi
  ) where

import Control.Monad
import Control.Lens
import Control.Concurrent (threadDelay, takeMVar, putMVar, newMVar, MVar)
import Data.ByteString (ByteString)

import qualified Control.Concurrent.Chan.Unagi.Bounded as Bounded
import qualified Control.Concurrent.Chan.Unagi as Unagi
import qualified Control.Concurrent.Chan.Unagi.NoBlocking as NoBlock

import Data.Typeable
import Data.AffineSpace ((.-.))
import Data.Thyme.Clock (UTCTime, microseconds, getCurrentTime)

import Juno.Types.Base
import Juno.Types.Event
import Juno.Types.Message.Signed
import Juno.Types.Message

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

newtype InboundAER = InboundAER { _unInboundAER :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

newtype InboundCMD = InboundCMD { _unInboundCMD :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

newtype InboundGeneral = InboundGeneral { _unInboundGeneral :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

newtype InboundRVorRVR = InboundRVorRVR { _unInboundRVorRVR :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

newtype OutboundGeneral = OutboundGeneral { _unOutboundGeneral :: Envelope}
  deriving (Show, Eq, Typeable)

newtype OutboundAerRvRvr = OutboundAerRvRvr { _unOutboundAerRvRvr :: Envelope}
  deriving (Show, Eq, Typeable)

directMsg :: NodeId -> ByteString -> OutboundGeneral
directMsg n b = OutboundGeneral $ Envelope (Topic $ unAlias $ _alias n, b)

broadcastMsg :: ByteString -> OutboundGeneral
broadcastMsg b = OutboundGeneral $ Envelope (Topic $ "all", b)

aerRvRvrMsg :: ByteString -> OutboundAerRvRvr
aerRvRvrMsg b = OutboundAerRvRvr $ Envelope (Topic $ "all", b)

newtype InternalEvent = InternalEvent { _unInternalEvent :: Event}
  deriving (Show, Typeable)

newtype InboundAERChannel =
  InboundAERChannel (NoBlock.InChan InboundAER, MVar (NoBlock.Stream InboundAER))
newtype InboundCMDChannel =
  InboundCMDChannel (NoBlock.InChan InboundCMD, MVar (NoBlock.Stream InboundCMD))
newtype InboundRVorRVRChannel =
  InboundRVorRVRChannel (Unagi.InChan InboundRVorRVR, MVar (Maybe (Unagi.Element InboundRVorRVR, IO InboundRVorRVR), Unagi.OutChan InboundRVorRVR))
newtype InboundGeneralChannel =
  InboundGeneralChannel (NoBlock.InChan InboundGeneral, MVar (NoBlock.Stream InboundGeneral))
newtype OutboundGeneralChannel =
  OutboundGeneralChannel (Unagi.InChan OutboundGeneral, MVar (Maybe (Unagi.Element OutboundGeneral, IO OutboundGeneral), Unagi.OutChan OutboundGeneral))
newtype OutboundAerRvRvrChannel =
  OutboundAerRvRvrChannel (Unagi.InChan OutboundAerRvRvr, MVar (Maybe (Unagi.Element OutboundAerRvRvr, IO OutboundAerRvRvr), Unagi.OutChan OutboundAerRvRvr))
newtype InternalEventChannel =
  InternalEventChannel (Bounded.InChan InternalEvent, MVar (Maybe (Bounded.Element InternalEvent, IO InternalEvent), Bounded.OutChan InternalEvent))

class Comms f c | c -> f where
  initComms :: IO c
  readComm :: c -> IO f
  readComms :: c -> Int -> IO [f]
  writeComm :: c -> f -> IO ()

instance Comms InboundAER InboundAERChannel where
  initComms = InboundAERChannel <$> initCommsNoBlock
  readComm (InboundAERChannel (_,o)) = readCommNoBlock o
  readComms (InboundAERChannel (_,o)) = readCommsNoBlock o
  writeComm (InboundAERChannel (i,_)) = writeCommNoBlock i

instance Comms InboundCMD InboundCMDChannel where
  initComms = InboundCMDChannel <$> initCommsNoBlock
  readComm (InboundCMDChannel (_,o))  = readCommNoBlock o
  readComms (InboundCMDChannel (_,o)) = readCommsNoBlock o
  writeComm (InboundCMDChannel (i,_)) = writeCommNoBlock i

instance Comms InboundGeneral InboundGeneralChannel where
  initComms = InboundGeneralChannel <$> initCommsNoBlock
  readComm (InboundGeneralChannel (_,o))  = readCommNoBlock o
  readComms (InboundGeneralChannel (_,o)) = readCommsNoBlock o
  writeComm (InboundGeneralChannel (i,_)) = writeCommNoBlock i

instance Comms InboundRVorRVR InboundRVorRVRChannel where
  initComms = InboundRVorRVRChannel <$> initCommsUnagi
  readComm (InboundRVorRVRChannel (_,o)) = readCommUnagi o
  readComms (InboundRVorRVRChannel (_,o)) = readCommsUnagi o
  writeComm (InboundRVorRVRChannel (i,_)) = writeCommUnagi i

instance Comms OutboundGeneral OutboundGeneralChannel where
  initComms = OutboundGeneralChannel <$> initCommsUnagi
  readComm (OutboundGeneralChannel (_,o)) = readCommUnagi o
  readComms (OutboundGeneralChannel (_,o)) = readCommsUnagi o
  writeComm (OutboundGeneralChannel (i,_)) = writeCommUnagi i

instance Comms OutboundAerRvRvr OutboundAerRvRvrChannel where
  initComms = OutboundAerRvRvrChannel <$> initCommsUnagi
  readComm (OutboundAerRvRvrChannel (_,o)) = readCommUnagi o
  readComms (OutboundAerRvRvrChannel (_,o)) = readCommsUnagi o
  writeComm (OutboundAerRvRvrChannel (i,_)) = writeCommUnagi i

instance Comms InternalEvent InternalEventChannel where
  initComms = InternalEventChannel <$> initCommsBounded
  readComm (InternalEventChannel (_,o)) = readCommBounded o
  readComms (InternalEventChannel (_,o)) = readCommsBounded o
  writeComm (InternalEventChannel (i,_)) = writeCommBounded i

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
