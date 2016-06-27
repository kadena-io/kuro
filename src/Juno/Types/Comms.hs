{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Types.Comms
  ( Comms(..)
  , CommChannel(..), inChan, outChan
  , Dispatch(..), inboundAER, inboundCMD, inboundRVorRVR, inboundGeneral, outboundGeneral, internalEvent
  , initDispatch
  , InboundAER(..)
  , InboundCMD(..)
  , InboundRVorRVR(..)
  , InboundGeneral(..)
  , OutboundGeneral(..)
  , InternalEvent(..)
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

class Comms c where
  type InChan c :: *
  type OutChan c :: *
  initComms :: IO (CommChannel c)
  readComm :: OutChan c -> IO c
  readComms :: OutChan c -> Int -> IO [c]
  writeComm :: InChan c -> c -> IO ()

data CommChannel a = CommChannel
  { _inChan :: InChan a
  , _outChan :: OutChan a
  } deriving (Typeable)

newtype InboundAER = InboundAER { _unInboundAER :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

instance Comms InboundAER where
  type InChan InboundAER  = NoBlock.InChan InboundAER
  type OutChan InboundAER = MVar (NoBlock.Stream InboundAER)
  initComms = do
    (i, o) <- NoBlock.newChan
    m <- newMVar =<< return . head =<< NoBlock.streamChan 1 o
    return $ CommChannel i m
  readComm m = do
    possibleRead <- takeMVar m
    t <- NoBlock.tryReadNext possibleRead
    case t of
      NoBlock.Pending -> putMVar m possibleRead >> readComm m
      NoBlock.Next v possibleRead' -> putMVar m possibleRead' >> return v
  readComms m cnt = do
    possibleRead <- takeMVar m
    blog <- readStream m possibleRead cnt
    if blog /= []
      then return blog
      else threadDelay 1000 >> return []
  writeComm i c = NoBlock.writeChan i c

newtype InboundCMD = InboundCMD { _unInboundCMD :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

instance Comms InboundCMD where
  type InChan InboundCMD  = NoBlock.InChan InboundCMD
  type OutChan InboundCMD = MVar (NoBlock.Stream InboundCMD)
  initComms = do
    (i, o) <- NoBlock.newChan
    m <- newMVar =<< return . head =<< NoBlock.streamChan 1 o
    return $ CommChannel i m
  readComm m = do
    possibleRead <- takeMVar m
    t <- NoBlock.tryReadNext possibleRead
    case t of
      NoBlock.Pending -> putMVar m possibleRead >> readComm m
      NoBlock.Next v possibleRead' -> putMVar m possibleRead' >> return v
  readComms m cnt = do
    possibleRead <- takeMVar m
    blog <- readStream m possibleRead cnt
    if blog /= []
      then return blog
      else threadDelay 1000 >> return []
  writeComm i c = NoBlock.writeChan i c

newtype InboundRVorRVR = InboundRVorRVR { _unInboundRVorRVR :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

instance Comms InboundRVorRVR where
  type InChan InboundRVorRVR  = Unagi.InChan InboundRVorRVR
  type OutChan InboundRVorRVR = MVar (Maybe (Unagi.Element InboundRVorRVR, IO InboundRVorRVR), Unagi.OutChan InboundRVorRVR)
  initComms = do
    (i, o) <- Unagi.newChan
    m <- newMVar (Nothing, o)
    return $ CommChannel i m
  readComm m = do
    (e, o) <- takeMVar m
    case e of
      Nothing -> do
        r <- Unagi.readChan o
        putMVar m (Nothing, o)
        return r
      Just (_,blockingRead) -> do
        putMVar m (Nothing,o) >> blockingRead
  readComms m cnt = do
    (e, o) <- takeMVar m
    case e of
      Nothing -> do
        readRegularUnagi Nothing m o cnt
      Just (v,blockingRead) -> do
        r <- Unagi.tryRead v
        case r of
          Nothing -> putMVar m (Just (v,blockingRead),o) >> return []
          Just v' -> readRegularUnagi (Just v') m o cnt
  writeComm i c = Unagi.writeChan i c

newtype InboundGeneral = InboundGeneral { _unInboundGeneral :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

instance Comms InboundGeneral where
  type InChan InboundGeneral  = NoBlock.InChan InboundGeneral
  type OutChan InboundGeneral = MVar (NoBlock.Stream InboundGeneral)
  initComms = do
    (i, o) <- NoBlock.newChan
    m <- newMVar =<< return . head =<< NoBlock.streamChan 1 o
    return $ CommChannel i m
  readComm m = do
    possibleRead <- takeMVar m
    t <- NoBlock.tryReadNext possibleRead
    case t of
      NoBlock.Pending -> putMVar m possibleRead >> readComm m
      NoBlock.Next v possibleRead' -> putMVar m possibleRead' >> return v
  readComms m cnt = do
    possibleRead <- takeMVar m
    blog <- readStream m possibleRead cnt
    if blog /= []
      then return blog
      else threadDelay 1000 >> return []
  writeComm i c = NoBlock.writeChan i c

newtype OutboundGeneral = OutboundGeneral { _unOutboundGeneral :: OutBoundMsg String ByteString}
  deriving (Show, Eq, Typeable)

instance Comms OutboundGeneral where
  type InChan OutboundGeneral  = Unagi.InChan OutboundGeneral
  type OutChan OutboundGeneral = MVar (Maybe (Unagi.Element OutboundGeneral, IO OutboundGeneral), Unagi.OutChan OutboundGeneral)
  initComms = do
    (i, o) <- Unagi.newChan
    m <- newMVar (Nothing, o)
    return $ CommChannel i m
  readComm m = do
    (e, o) <- takeMVar m
    case e of
      Nothing -> do
        r <- Unagi.readChan o
        putMVar m (Nothing, o)
        return r
      Just (_,blockingRead) -> do
        putMVar m (Nothing,o) >> blockingRead
  readComms m cnt = do
    (e, o) <- takeMVar m
    case e of
      Nothing -> do
        readRegularUnagi Nothing m o cnt
      Just (v,blockingRead) -> do
        r <- Unagi.tryRead v
        case r of
          Nothing -> putMVar m (Just (v,blockingRead),o) >> return []
          Just v' -> readRegularUnagi (Just v') m o cnt
  writeComm i c = Unagi.writeChan i c

newtype InternalEvent = InternalEvent { _unInternalEvent :: Event}
  deriving (Show, Typeable)

instance Comms InternalEvent where
  type InChan InternalEvent  = Bounded.InChan InternalEvent
  type OutChan InternalEvent = MVar (Maybe (Bounded.Element InternalEvent, IO InternalEvent), Bounded.OutChan InternalEvent)
  initComms = do
    (i, o) <- Bounded.newChan 20
    m <- newMVar (Nothing, o)
    return $ CommChannel i m
  readComm m = do
    (e, o) <- takeMVar m
    case e of
      Nothing -> do
        r <- Bounded.readChan o
        putMVar m (Nothing, o)
        return r
      Just (_,blockingRead) -> do
        putMVar m (Nothing,o) >> blockingRead
  readComms m cnt = do
    (e, o) <- takeMVar m
    case e of
      Nothing -> do
        readBoundedUnagi Nothing m o cnt
      Just (v,blockingRead) -> do
        r <- Bounded.tryRead v
        case r of
          Nothing -> putMVar m (Just (v,blockingRead),o) >> return []
          Just v' -> readBoundedUnagi (Just v') m o cnt
  writeComm i c = Bounded.writeChan i c

data Dispatch = Dispatch
  { _inboundAER :: CommChannel InboundAER
  , _inboundCMD :: CommChannel InboundCMD
  , _inboundRVorRVR :: CommChannel InboundRVorRVR
  , _inboundGeneral :: CommChannel InboundGeneral
  , _outboundGeneral :: CommChannel OutboundGeneral
  , _internalEvent :: CommChannel InternalEvent
  } deriving (Typeable)

initDispatch :: IO Dispatch
initDispatch = Dispatch
            <$> initComms
            <*> initComms
            <*> initComms
            <*> initComms
            <*> initComms
            <*> initComms

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

makeLenses ''CommChannel
makeLenses ''Dispatch
