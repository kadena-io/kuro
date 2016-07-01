{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE BangPatterns #-}

module Juno.Messaging.ZMQ (
  runMsgServer
  ) where

import Control.Lens
import Control.Concurrent (forkIO, threadDelay, yield, newMVar, takeMVar, putMVar, yield)
import qualified Control.Concurrent.Async as Async
import Control.Monad.State.Strict
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import System.ZMQ4.Monadic
import Data.Thyme.Clock
import Data.Serialize
import qualified Data.List.NonEmpty as NonEmpty

import Juno.Types

sendProcess :: OutboundGeneralChannel
            -> Rolodex String (Socket z Push)
            -> ZMQ z ()
sendProcess outChan' !r = do
  -- liftIO $ debug $ "[ZMQ_SEND_PROCESS] Entered"
  rMvar <- liftIO $ newMVar r
  forever $ do
    (OutBoundMsg !addrs !msg) <- liftIO $! _unOutboundGeneral <$> readComm outChan'
    -- liftIO $ debug $ "[ZMQ_SEND_PROCESS] Sending message to " ++ (show addrs) ++ " ## MSG ## " ++ show msg
    r' <- liftIO $ takeMVar rMvar
    !newRol <- updateRolodex r' addrs
    !toPoll <- recipList newRol addrs
    mapM_ (\s -> send s [] msg) toPoll
    liftIO $ putMVar rMvar newRol
    -- liftIO $ debug $ "[ZMQ_SEND_PROCESS] Sent Msg"

updateRolodex :: Rolodex String (Socket z Push) -> Recipients String -> ZMQ z (Rolodex String (Socket z Push))
updateRolodex r@(Rolodex !_rol) RAll = return $! r
updateRolodex r@(Rolodex !rol) (RSome !addrs) =
  if Set.isSubsetOf addrs $! Map.keysSet rol
  then return $! r
  else do
    !a <- addNewAddrs r $! Set.toList addrs
    return $! a
updateRolodex r@(Rolodex !rol) (ROne !addr) =
  if Set.member addr $! Map.keysSet rol
  then return $! r
  else do
    !a <- addNewAddrs r [addr]
    return $! a

addNewAddrs :: Rolodex String (Socket z Push) -> [Addr String] -> ZMQ z (Rolodex String (Socket z Push))
addNewAddrs !r [] = return r
addNewAddrs (Rolodex !r) (x:xs) = do
  !r' <- if Map.member x r
        then return $! Rolodex r
        else do
          s <- socket Push
          _ <- connect s $ _unAddr x
          return $! Rolodex $! Map.insert x (ListenOn s) r
  r' `seq` addNewAddrs r' xs

recipList :: Rolodex String (Socket z Push) -> Recipients String -> ZMQ z [Socket z Push]
recipList (Rolodex r) RAll = return $! _unListenOn <$> Map.elems r
recipList (Rolodex r) (RSome addrs) = return $! _unListenOn . (r Map.!) <$> Set.toList addrs
recipList (Rolodex r) (ROne addr) = return $! _unListenOn <$> [r Map.! addr]

nodeIdToZmqAddr :: NodeId -> String
nodeIdToZmqAddr NodeId{..} = "tcp://" ++ _host ++ ":" ++ show _port

runMsgServer :: Dispatch
             -> NodeId
             -> [NodeId]
             -> (String -> IO ())
             -> IO ()
runMsgServer dispatch me addrList debug = void $ forkIO $ forever $ do
  inboxWrite <- return $ dispatch ^. inboundGeneral
  cmdInboxWrite <- return $ dispatch ^. inboundCMD
  aerInboxWrite <- return $ dispatch ^. inboundAER
  rvAndRvrWrite <- return $ dispatch ^. inboundRVorRVR
  outboxRead <- return $ dispatch ^. outboundGeneral
  pubRead <- return $ dispatch ^. outboundPub

  zmqThread <- Async.async $ runZMQ $ do
    -- liftIO $ debug $ "[ZMQ_THREAD] Launching..."
    zmqReceiver <- async $ do
      -- liftIO $ debug $ "[ZMQ_RECEIVER] Launching..."
      sock <- socket Pull
      _ <- bind sock $ nodeIdToZmqAddr me
      forever $ do
        newMsg <- receive sock
        ts <- liftIO getCurrentTime
        case decode newMsg of
          Left err -> do
            liftIO $ debug $ "[ZMQ_RECEIVER] Failed to deserialize to SignedRPC [Msg]: " ++ show newMsg
            liftIO $ debug $ "[ZMQ_RECEIVER] Failed to deserialize to SignedRPC [Error]: " ++ err
            liftIO yield
          Right s@(SignedRPC dig _)
            | _digType dig == RV || _digType dig == RVR ->
              liftIO $ writeComm rvAndRvrWrite (InboundRVorRVR (ReceivedAt ts, s)) >> yield
            | _digType dig == CMD || _digType dig == CMDB ->
              liftIO $ writeComm cmdInboxWrite (InboundCMD (ReceivedAt ts, s)) >> yield
            | _digType dig == AER ->
              liftIO $ writeComm aerInboxWrite (InboundAER (ReceivedAt ts, s)) >> yield
            | otherwise           ->
              liftIO $ writeComm inboxWrite (InboundGeneral (ReceivedAt ts, s)) >> yield

    -- Testing out using Pub sockets for AER's
    -- TODO: figure out how to catch failures on _zmqPub like in zmqSender
    _zmqPub <- liftM Async.link $ async $ do
      liftIO $ debug $ "[ZMQ_PUB] Launching..."
      pubSock <- socket Pub
      _ <- bind pubSock $ nodeIdToZmqAddr $ me { _port = 5000 + _port me}
      forever $ do
        !msg <- liftIO $! _unOutboundPub <$> readComm pubRead
        sendMulti pubSock $ NonEmpty.fromList ["all", msg]

    liftIO $ threadDelay 100000 -- to be sure that the receive side is up first

    -- liftIO $ debug $ "[ZMQ_SENDER] Launching..."
    zmqSender <- async $ do
      rolodex <- addNewAddrs (Rolodex Map.empty) $ fmap (Addr . nodeIdToZmqAddr) addrList
      void $ sendProcess outboxRead rolodex
      -- liftIO $ debug $ "[ZMQ_SENDER] Exiting"

    _zmqSub <- liftM Async.link $ async $ do
      subSocket <- socket Sub
      subscribe subSocket "all"
      void $ mapM_ (\addr -> do
          _ <- connect subSocket $ nodeIdToZmqAddr $ addr { _port = 5000 + _port addr }
          liftIO $ debug $ "[ZMQ_SUB] made sub socket for: " ++ (show $ nodeIdToZmqAddr $ addr { _port = 5000 + _port addr })
          ) addrList
      forever $ do
        _topic <- receive subSocket
        newMsg <- receive subSocket
        ts <- liftIO getCurrentTime
        case decode newMsg of
          Left err -> do
            liftIO $ debug $ "[ZMQ_SUB] Failed to deserialize to SignedRPC [Msg]: " ++ show newMsg
            liftIO $ debug $ "[ZMQ_SUB] Failed to deserialize to SignedRPC [Error]: " ++ err
            liftIO yield
          Right s@(SignedRPC dig _)
            | _digType dig == RV || _digType dig == RVR -> do
--              liftIO $ debug $ "[ZMQ_SUB] Received RVR from: " ++ (show $ _alias $ _digNodeId dig)
              liftIO $ writeComm rvAndRvrWrite (InboundRVorRVR (ReceivedAt ts, s)) >> yield
            | _digType dig == CMD || _digType dig == CMDB -> do
--              liftIO $ debug $ "[ZMQ_SUB] Received CMD or CMDB, but I shouldn't have!"
              liftIO $ writeComm cmdInboxWrite (InboundCMD (ReceivedAt ts, s)) >> yield
            | _digType dig == AER -> do
--              liftIO $ debug $ "[ZMQ_SUB] Received AER from: " ++ (show $ _alias $ _digNodeId dig)
              liftIO $ writeComm aerInboxWrite (InboundAER (ReceivedAt ts, s)) >> yield
            | otherwise           -> do
--              liftIO $ debug $ "[ZMQ_SUB] Received " ++ (show $ _digType dig) ++ " from " ++ (show $ _alias $ _digNodeId dig)
              liftIO $ writeComm inboxWrite (InboundGeneral (ReceivedAt ts, s)) >> yield

    liftIO $ (Async.waitEitherCancel zmqReceiver zmqSender) >>= \res' -> case res' of
      Left () -> liftIO $ debug $ "[ZMQ_RECEIVER] returned with ()"
      Right v -> liftIO $ debug $ "[ZMQ_SENDER] returned with " ++ show v
    liftIO $ debug $ "[ZMQ_THREAD] Exiting"
  res <- Async.waitCatch zmqThread
  Async.cancel zmqThread >> case res of
    Right () -> debug $ "[ZMQ_MSG_SERVER] died returning () with no details"
    Left err -> debug $ "[ZMQ_MSG_SERVER] exception " ++ show err
