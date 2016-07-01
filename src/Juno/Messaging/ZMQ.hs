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
import Control.Exception.Base
import Control.Concurrent (forkIO, threadDelay, yield)
import qualified Control.Concurrent.Async as Async
import Control.Monad.State.Strict
import System.ZMQ4.Monadic
import Data.Thyme.Clock
import Data.Serialize

import Juno.Types

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
  aerRvRvrRead <- return $ dispatch ^. outboundAerRvRvr

  zmqGeneralThread <- Async.async $ runZMQ $ do
    -- ZMQ Pub Thread
    zmqPub <- async $ do
      liftIO $ debug "[ZMQ_GENERAL_PUB] Launching..."
      pubSock <- socket Pub
      _ <- bind pubSock $ nodeIdToZmqAddr me
      forever $ do
        !msg <- liftIO $! sealEnvelope . _unOutboundGeneral <$> readComm outboxRead
        --liftIO $ debug $ "[ZMQ_GENERAL_PUB] publishing msg to: " ++ show (NonEmpty.head msg)
        sendMulti pubSock msg

    liftIO $ threadDelay 100000 -- to be sure that the receive side is up first

    zmqSub <- async $ do
      subSocket <- socket Sub
      subscribe subSocket "all" -- the topic for broadcast messages
      liftIO $ debug $ "[ZMQ_GENERAL_SUB] Subscribed to: \"all\""
      subscribe subSocket $ unAlias $ _alias me
      liftIO $ debug $ "[ZMQ_GENERAL_SUB] Subscribed to: " ++ show (unAlias $ _alias me)
      void $ mapM_ (\addr -> do
          _ <- connect subSocket $ nodeIdToZmqAddr $ addr
          liftIO $ debug $ "[ZMQ_GENERAL_SUB] made sub socket for: " ++ (show $ nodeIdToZmqAddr addr )
          ) addrList
      forever $ do
        env <- openEnvelope <$> receiveMulti subSocket
        ts <- liftIO getCurrentTime
        case env of
          Left err ->
            liftIO $ debug $ "[ZMQ_GENERAL_SUB] " ++ show err
          Right (Envelope (_topic',newMsg)) -> do
            --liftIO $ debug $ "[ZMQ_GENERAL_SUB] got msg on topic: " ++ show (_unTopic topic')
            case decode newMsg of
              Left err -> do
                liftIO $ debug $ "[ZMQ_GENERAL_SUB] Failed to deserialize to SignedRPC [Msg]: " ++ show newMsg
                liftIO $ debug $ "[ZMQ_GENERAL_SUB] Failed to deserialize to SignedRPC [Error]: " ++ err
                liftIO yield
              Right s@(SignedRPC dig _)
                | _digType dig == RV || _digType dig == RVR -> do
                  --liftIO $ debug $ "[ZMQ_GENERAL_SUB] Received RVR from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm rvAndRvrWrite (InboundRVorRVR (ReceivedAt ts, s)) >> yield
                | _digType dig == CMD || _digType dig == CMDB -> do
                  --liftIO $ debug $ "[ZMQ_GENERAL_SUB] Received CMD or CMDB from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm cmdInboxWrite (InboundCMD (ReceivedAt ts, s)) >> yield
                | _digType dig == AER -> do
                  --liftIO $ debug $ "[ZMQ_GENERAL_SUB] Received AER from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm aerInboxWrite (InboundAER (ReceivedAt ts, s)) >> yield
                | otherwise           -> do
                  --liftIO $ debug $ "[ZMQ_GENERAL_SUB] Received " ++ (show $ _digType dig) ++ " from " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm inboxWrite (InboundGeneral (ReceivedAt ts, s)) >> yield

    liftIO $ do
      res <- Async.waitEitherCancel zmqSub zmqPub
      case res of
        Left (Left (SomeException err)) -> liftIO $ debug $ "[ZMQ_SUB] errored with: " ++ show err
        Left (Right _) -> liftIO $ debug $ "[ZMQ_SUB] errored with something unshowable..."
        Right (Left (SomeException err)) -> liftIO $ debug $ "[ZMQ_PUB] errored with: " ++ show err
        Right (Right _) -> liftIO $ debug $ "[ZMQ_PUB] errored with something unshowable..."
    liftIO $ debug $ "[ZMQ_THREAD] Exiting"
    return $ Right ()

  -- TODO: research if running two ZMQ's is better for scaling/speed than one with more sockets
  -- My gut tells me that it's either the same or faster to have a dedicated instance a load that scales n^2
  -- This one will run on port (+5000)
  zmqAeRvRvrThread <- Async.async $ runZMQ $ do
    -- ZMQ Pub Thread
    zmqPub <- async $ do
      liftIO $ debug $ "[ZMQ_AeRvRvr_PUB] Launching..."
      pubSock <- socket Pub
      _ <- bind pubSock $ nodeIdToZmqAddr $ me { _port = 5000 + _port me }
      forever $ do
        !msg <- liftIO $! sealEnvelope . _unOutboundAerRvRvr <$> readComm aerRvRvrRead
        --liftIO $ debug $ "[ZMQ_AerRvRvr_PUB] publishing msg to: " ++ show (NonEmpty.head msg)
        sendMulti pubSock msg

    liftIO $ threadDelay 100000 -- to be sure that the receive side is up first

    zmqSub <- async $ do
      subSocket <- socket Sub
      subscribe subSocket "" -- the topic for broadcast messages
      liftIO $ debug $ "[ZMQ_AerRvRvr_SUB] Subscribed to: \"\" (everything)"
      void $ mapM_ (\addr -> do
          _ <- connect subSocket $ nodeIdToZmqAddr $ addr { _port = 5000 + _port addr }
          liftIO $ debug $ "[ZMQ_AerRvRvr_SUB] made sub socket for: " ++ (show $ nodeIdToZmqAddr $ addr { _port = 5000 + _port addr })
          ) addrList
      forever $ do
        env <- openEnvelope <$> receiveMulti subSocket
        ts <- liftIO getCurrentTime
        case env of
          Left err ->
            liftIO $ debug $ "[ZMQ_AerRvRvr_SUB] " ++ show err
          Right (Envelope (_topic',newMsg)) -> do
            --liftIO $ debug $ "[ZMQ_AerRvRvr_SUB] got msg on topic: " ++ show (_unTopic topic')
            case decode newMsg of
              Left err -> do
                liftIO $ debug $ "[ZMQ_AerRvRvr_SUB] Failed to deserialize to SignedRPC [Msg]: " ++ show newMsg
                liftIO $ debug $ "[ZMQ_AerRvRvr_SUB] Failed to deserialize to SignedRPC [Error]: " ++ err
                liftIO yield
              Right s@(SignedRPC dig _)
                | _digType dig == RV || _digType dig == RVR -> do
                  --liftIO $ debug $ "[ZMQ_AerRvRvr_SUB] Received RVR from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm rvAndRvrWrite (InboundRVorRVR (ReceivedAt ts, s)) >> yield
                | _digType dig == CMD || _digType dig == CMDB -> do
                  liftIO $ debug $ "[ZMQ_AerRvRvr_SUB] Received a CMD or CMDB but shouldn't have from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm cmdInboxWrite (InboundCMD (ReceivedAt ts, s)) >> yield
                | _digType dig == AER -> do
                  --liftIO $ debug $ "[ZMQ_AerRvRvr_SUB] Received AER from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm aerInboxWrite (InboundAER (ReceivedAt ts, s)) >> yield
                | otherwise           -> do
                  liftIO $ debug $ "[ZMQ_AerRvRvr_SUB] Received a "
                                   ++ (show $ _digType dig)
                                   ++ " that I shouldn't have from: "
                                   ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm inboxWrite (InboundGeneral (ReceivedAt ts, s)) >> yield

    liftIO $ do
      res <- Async.waitEitherCancel zmqSub zmqPub
      case res of
        Left (Left (SomeException err)) -> liftIO $ debug $ "[ZMQ_AerRvRvr_SUB] errored with: " ++ show err
        Left (Right _) -> liftIO $ debug $ "[ZMQ_AerRvRvr_SUB] errored with something unshowable..."
        Right (Left (SomeException err)) -> liftIO $ debug $ "[ZMQ_AerRvRvr_PUB] errored with: " ++ show err
        Right (Right _) -> liftIO $ debug $ "[ZMQ_AerRvRvr_PUB] errored with something unshowable..."
    liftIO $ debug $ "[ZMQ_AerRvRvr_THREAD] Exiting"
    return $ Right ()

  res <- Async.waitEitherCancel zmqGeneralThread zmqAeRvRvrThread
  case res of
    Left (Left (SomeException err)) -> liftIO $ debug $ "[ZMQ_GENERAL_THREAD] errored with: " ++ show err
    Left (Right _) -> liftIO $ debug $ "[ZMQ_GENERAL_THREAD] errored with something unshowable..."
    Right (Left (SomeException err)) -> liftIO $ debug $ "[ZMQ_AerRvRvr_THREAD] errored with: " ++ show err
    Right (Right _) -> liftIO $ debug $ "[ZMQ_AerRvRvr_THREAD] errored with something unshowable..."
