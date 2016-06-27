{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}

module Juno.Types.Comms
  ( Comms(..)
  , ReceivedAER(..)
  , ReceivedCMD(..)
  , ReceivedRVorRVR(..)
  , ReceivedGeneral(..)
  , OtherNodes(..)
  , ConsensusEvent(..)
  ) where

import Juno.Types.Base
import Juno.Types.Event
import Juno.Types.Message.Signed
import Juno.Types.Message

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
  initComms :: IO (InChan c, OutChan c)
  readComm :: OutChan c -> IO c
  readComms :: OutChan c -> Int -> IO [c]
  writeComm :: InChan c -> c -> IO ()

newtype ReceivedAER = ReceivedAER { _unReceivedAER :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

instance Comms ReceivedAER where
  type InChan ReceivedAER  = NoBlock.InChan ReceivedAER
  type OutChan ReceivedAER = MVar (NoBlock.Stream ReceivedAER)
  initComms = do
    (i, o) <- NoBlock.newChan
    m <- newMVar =<< return . head =<< NoBlock.streamChan 1 o
    return (i,m)
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

newtype ReceivedCMD = ReceivedCMD { _unReceivedCMD :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

instance Comms ReceivedCMD where
  type InChan ReceivedCMD  = NoBlock.InChan ReceivedCMD
  type OutChan ReceivedCMD = MVar (NoBlock.Stream ReceivedCMD)
  initComms = do
    (i, o) <- NoBlock.newChan
    m <- newMVar =<< return . head =<< NoBlock.streamChan 1 o
    return (i,m)
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

newtype ReceivedRVorRVR = ReceivedRVorRVR { _unReceivedRVorRVR :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

instance Comms ReceivedRVorRVR where
  type InChan ReceivedRVorRVR  = Unagi.InChan ReceivedRVorRVR
  type OutChan ReceivedRVorRVR = MVar (Maybe (Unagi.Element ReceivedRVorRVR, IO ReceivedRVorRVR), Unagi.OutChan ReceivedRVorRVR)
  initComms = do
    (i, o) <- Unagi.newChan
    m <- newMVar (Nothing, o)
    return (i,m)
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

newtype ReceivedGeneral = ReceivedGeneral { _unReceivedGeneral :: (ReceivedAt, SignedRPC)}
  deriving (Show, Eq, Typeable)

instance Comms ReceivedGeneral where
  type InChan ReceivedGeneral  = NoBlock.InChan ReceivedGeneral
  type OutChan ReceivedGeneral = MVar (NoBlock.Stream ReceivedGeneral)
  initComms = do
    (i, o) <- NoBlock.newChan
    m <- newMVar =<< return . head =<< NoBlock.streamChan 1 o
    return (i,m)
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

newtype OtherNodes = OtherNodes { _unOtherNodes :: OutBoundMsg String ByteString}
  deriving (Show, Eq, Typeable)

instance Comms OtherNodes where
  type InChan OtherNodes  = Unagi.InChan OtherNodes
  type OutChan OtherNodes = MVar (Maybe (Unagi.Element OtherNodes, IO OtherNodes), Unagi.OutChan OtherNodes)
  initComms = do
    (i, o) <- Unagi.newChan
    m <- newMVar (Nothing, o)
    return (i,m)
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

newtype ConsensusEvent = ConsensusEvent { _unConsensusEvent :: Event}
  deriving (Show, Typeable)

instance Comms ConsensusEvent where
  type InChan ConsensusEvent  = Bounded.InChan ConsensusEvent
  type OutChan ConsensusEvent = MVar (Maybe (Bounded.Element ConsensusEvent, IO ConsensusEvent), Bounded.OutChan ConsensusEvent)
  initComms = do
    (i, o) <- Bounded.newChan 20
    m <- newMVar (Nothing, o)
    return (i,m)
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
