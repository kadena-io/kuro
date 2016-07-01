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

  zmqThread <- Async.async $ runZMQ $ do
    -- ZMQ Pub Thread
    zmqPub <- async $ do
      liftIO $ debug $ "[ZMQ_PUB] Launching..."
      pubSock <- socket Pub
      _ <- bind pubSock $ nodeIdToZmqAddr $ me { _port = 5000 + _port me}
      forever $ do
        !msg <- liftIO $! sealEnvelope . _unOutboundGeneral <$> readComm outboxRead
        --liftIO $ debug $ "[ZMQ_PUB] publishing msg to: " ++ show (NonEmpty.head msg)
        sendMulti pubSock msg

    liftIO $ threadDelay 100000 -- to be sure that the receive side is up first

    zmqSub <- async $ do
      subSocket <- socket Sub
      subscribe subSocket "all" -- the topic for broadcast messages
      liftIO $ debug $ "[ZMQ_SUB] Subscribed to: \"all\""
      subscribe subSocket $ unAlias $ _alias me
      liftIO $ debug $ "[ZMQ_SUB] Subscribed to: " ++ show (unAlias $ _alias me)
      void $ mapM_ (\addr -> do
          _ <- connect subSocket $ nodeIdToZmqAddr $ addr { _port = 5000 + _port addr }
          liftIO $ debug $ "[ZMQ_SUB] made sub socket for: " ++ (show $ nodeIdToZmqAddr $ addr { _port = 5000 + _port addr })
          ) addrList
      forever $ do
        env <- openEnvelope <$> receiveMulti subSocket
        ts <- liftIO getCurrentTime
        case env of
          Left err ->
            liftIO $ debug $ "[ZMQ_SUB] " ++ show err
          Right (Envelope (_topic',newMsg)) -> do
            --liftIO $ debug $ "[ZMQ_SUB] got msg on topic: " ++ show (_unTopic topic')
            case decode newMsg of
              Left err -> do
                liftIO $ debug $ "[ZMQ_SUB] Failed to deserialize to SignedRPC [Msg]: " ++ show newMsg
                liftIO $ debug $ "[ZMQ_SUB] Failed to deserialize to SignedRPC [Error]: " ++ err
                liftIO yield
              Right s@(SignedRPC dig _)
                | _digType dig == RV || _digType dig == RVR -> do
                  --liftIO $ debug $ "[ZMQ_SUB] Received RVR from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm rvAndRvrWrite (InboundRVorRVR (ReceivedAt ts, s)) >> yield
                | _digType dig == CMD || _digType dig == CMDB -> do
                  --liftIO $ debug $ "[ZMQ_SUB] Received CMD or CMDB from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm cmdInboxWrite (InboundCMD (ReceivedAt ts, s)) >> yield
                | _digType dig == AER -> do
                  --liftIO $ debug $ "[ZMQ_SUB] Received AER from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm aerInboxWrite (InboundAER (ReceivedAt ts, s)) >> yield
                | otherwise           -> do
                  --liftIO $ debug $ "[ZMQ_SUB] Received " ++ (show $ _digType dig) ++ " from " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm inboxWrite (InboundGeneral (ReceivedAt ts, s)) >> yield

    liftIO $ do
      res <- Async.waitEitherCancel zmqSub zmqPub
      case res of
        Left (Left (SomeException err)) -> liftIO $ debug $ "[ZMQ_SUB] errored with: " ++ show err
        Left (Right _) -> liftIO $ debug $ "[ZMQ_SUB] errored with something unshowable..."
        Right (Left (SomeException err)) -> liftIO $ debug $ "[ZMQ_PUB] errored with: " ++ show err
        Right (Right _) -> liftIO $ debug $ "[ZMQ_PUB] errored with something unshowable..."
    liftIO $ debug $ "[ZMQ_THREAD] Exiting"
  res <- Async.waitCatch zmqThread
  Async.cancel zmqThread >> case res of
    Right () -> debug $ "[ZMQ_MSG_SERVER] died returning () with no details"
    Left err -> debug $ "[ZMQ_MSG_SERVER] exception " ++ show err
