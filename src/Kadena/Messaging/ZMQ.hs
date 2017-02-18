{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE BangPatterns #-}

module Kadena.Messaging.ZMQ (
  runMsgServer
  ) where

import Control.Lens
import Control.Exception.Base
import Control.Concurrent (yield, newEmptyMVar, takeMVar, putMVar)
import Control.Concurrent.Async (Async)
import qualified Control.Concurrent.Async as Async
import Control.Monad.State.Strict
import System.ZMQ4.Monadic
import Data.Thyme.Clock
import Data.Serialize

import Kadena.Types

nodeIdToZmqAddr :: NodeId -> String
nodeIdToZmqAddr NodeId{..} = "tcp://" ++ _host ++ ":" ++ show _port

zmqGenPub, zmqGenSub, zmqAerPub, zmqAerSub :: String
zmqGenPub = "[Zmq|Gen|Pub]: "
zmqGenSub = "[Zmq|Gen|Sub]: "
zmqAerPub = "[Zmq|Aer|Pub]: "
zmqAerSub = "[Zmq|Aer|Sub]: "

runMsgServer :: Dispatch
             -> NodeId
             -> [NodeId]
             -> (String -> IO ())
             -> IO (Async ())
runMsgServer dispatch me addrList debug = Async.async $ forever $ do
  inboxWrite <- return $ dispatch ^. inboundGeneral
  cmdInboxWrite <- return $ dispatch ^. inboundCMD
  aerInboxWrite <- return $ dispatch ^. inboundAER
  rvAndRvrWrite <- return $ dispatch ^. inboundRVorRVR
  outboxRead <- return $ dispatch ^. outboundGeneral
  aerRvRvrRead <- return $ dispatch ^. outboundAerRvRvr

  semephory <- newEmptyMVar -- this MVar is for coordinating the lighting of ZMQ. There's an annoying segfault/malloc error that I think is caused by ZMQ.

  zmqGeneralThread <- Async.async $ runZMQ $ do
    -- ZMQ Pub Thread
    zmqPub <- async $ do
      liftIO $ debug $ zmqGenPub ++ "launch!"
      pubSock <- socket Pub
      _ <- bind pubSock $ nodeIdToZmqAddr me
      liftIO $ putMVar semephory ()
      forever $ do
        !msgs <- liftIO (_unOutboundGeneral <$> readComm outboxRead) >>= return . fmap sealEnvelope
        --liftIO $ debug $ "[ZMQ_GENERAL_PUB] publishing msg to: " ++ show (NonEmpty.head msg)
        mapM_ (sendMulti pubSock) msgs

    liftIO $ void $ takeMVar semephory

    zmqSub <- async $ do
      subSocket <- socket Sub
      subscribe subSocket "all" -- the topic for broadcast messages
      liftIO $ debug $ zmqGenSub ++ "subscribed to: \"all\""
      subscribe subSocket $ unAlias $ _alias me
      liftIO $ debug $ zmqGenSub ++ "subscribed to: " ++ show (unAlias $ _alias me)
      void $ mapM_ (\addr -> do
          _ <- connect subSocket $ nodeIdToZmqAddr $ addr
          liftIO $ debug $  zmqGenSub ++ "made sub socket for: " ++ (show $ nodeIdToZmqAddr addr )
          ) addrList
      liftIO $ putMVar semephory ()
      forever $ do
        env <- openEnvelope <$> receiveMulti subSocket
        ts <- liftIO getCurrentTime
        case env of
          Left err ->
            liftIO $ debug $  zmqGenSub ++ show err
          Right (Envelope (_topic',newMsg)) -> do
            --liftIO $ debug $  zmqGenSub ++ "got msg on topic: " ++ show (_unTopic topic')
            case decode newMsg of
              Left err -> do
                liftIO $ debug $  zmqGenSub ++ "failed to deserialize to SignedRPC [Msg]: " ++ show newMsg
                liftIO $ debug $  zmqGenSub ++ "failed to deserialize to SignedRPC [Error]: " ++ err
                liftIO yield
              Right s@(SignedRPC dig _)
                | _digType dig == RV || _digType dig == RVR -> do
                  --liftIO $ debug $ "[ZMQ_GENERAL_SUB] Received RVR from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm rvAndRvrWrite (InboundRVorRVR (ReceivedAt ts, s)) >> yield
                | _digType dig == FWD -> do
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
        Left (Left (SomeException err)) -> liftIO $ debug $ zmqGenSub ++ "errored with: " ++ show err
        Left (Right _) -> liftIO $ debug $ zmqGenSub ++ "errored with something unshowable..."
        Right (Left (SomeException err)) -> liftIO $ debug $ zmqGenPub ++ "errored with: " ++ show err
        Right (Right _) -> liftIO $ debug $ zmqGenPub ++"errored with something unshowable..."
    liftIO $ debug $ "[Zmq|Gen] exiting"
    return $ Right ()

  liftIO $ void $ takeMVar semephory
  -- TODO: research if running two ZMQ's is better for scaling/speed than one with more sockets
  -- My gut tells me that it's either the same or faster to have a dedicated instance a load that scales n^2
  -- This one will run on port (+5000)
  zmqAeRvRvrThread <- Async.async $ runZMQ $ do
    -- ZMQ Pub Thread
    zmqPub <- async $ do
      liftIO $ debug $ zmqAerPub ++ "launch!"
      pubSock <- socket Pub
      _ <- bind pubSock $ nodeIdToZmqAddr $ me { _port = 5000 + _port me }
      liftIO $ putMVar semephory ()
      forever $ do
        !msgs <- liftIO (_unOutboundAerRvRvr <$> readComm aerRvRvrRead) >>= return . fmap sealEnvelope
        --liftIO $ debug $ zmqAerPub ++ "publishing msg to: " ++ show (NonEmpty.head msg)
        mapM_ (sendMulti pubSock) msgs

    liftIO $ void $ takeMVar semephory

    zmqSub <- async $ do
      subSocket <- socket Sub
      subscribe subSocket "" -- the topic for broadcast messages
      liftIO $ debug $ zmqAerSub ++ "subscribed to: \"\" (everything)"
      void $ mapM_ (\addr -> do
          _ <- connect subSocket $ nodeIdToZmqAddr $ addr { _port = 5000 + _port addr }
          liftIO $ debug $  zmqAerSub ++ "made sub socket for: " ++ (show $ nodeIdToZmqAddr $ addr { _port = 5000 + _port addr })
          ) addrList
      liftIO $ putMVar semephory ()
      forever $ do
        env <- openEnvelope <$> receiveMulti subSocket
        ts <- liftIO getCurrentTime
        case env of
          Left err ->
            liftIO $ debug $ zmqAerSub ++ show err
          Right (Envelope (_topic',newMsg)) -> do
            --liftIO $ debug $  zmqAerSub ++ "got msg on topic: " ++ show (_unTopic topic')
            case decode newMsg of
              Left err -> do
                liftIO $ debug $ zmqAerSub ++ "failed to deserialize to SignedRPC [Msg]: " ++ show newMsg
                liftIO $ debug $ zmqAerSub ++ "failed to deserialize to SignedRPC [Error]: " ++ err
                liftIO yield
              Right s@(SignedRPC dig _)
                | _digType dig == RV || _digType dig == RVR -> do
                  --liftIO $ debug $ zmqAerSub ++ "received RVR from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm rvAndRvrWrite (InboundRVorRVR (ReceivedAt ts, s)) >> yield
                | _digType dig == FWD -> do
                  liftIO $ debug $ zmqAerSub ++ "Received a CMD or CMDB but shouldn't have from: " ++ (show $ _digNodeId dig)
                  liftIO $ writeComm cmdInboxWrite (InboundCMD (ReceivedAt ts, s)) >> yield
                | _digType dig == AER -> do
                  --liftIO $ debug $ zmqAerSub ++ "received AER from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm aerInboxWrite (InboundAER (ReceivedAt ts, s)) >> yield
                | otherwise           -> do
                  liftIO $ debug $ zmqAerSub ++ "received a "
                                   ++ (show $ _digType dig)
                                   ++ " that I shouldn't have from: "
                                   ++ (show $ _digNodeId dig)
                  liftIO $ writeComm inboxWrite (InboundGeneral (ReceivedAt ts, s)) >> yield

    liftIO $ do
      res <- Async.waitEitherCancel zmqSub zmqPub
      case res of
        Left (Left (SomeException err)) -> liftIO $ debug $ zmqAerSub ++ "errored with: " ++ show err
        Left (Right _) -> liftIO $ debug $ zmqAerSub ++ "errored with something unshowable..."
        Right (Left (SomeException err)) -> liftIO $ debug $ zmqAerPub ++ "errored with: " ++ show err
        Right (Right _) -> liftIO $ debug $ zmqAerPub ++ "errored with something unshowable..."
    liftIO $ debug $ "[Zmq|Aer] exiting"
    return $ Right ()

  res <- Async.waitEitherCancel zmqGeneralThread zmqAeRvRvrThread
  case res of
    Left (Left (SomeException err)) -> liftIO $ debug $ "[Zmq|Gen] errored with: " ++ show err
    Left (Right _) -> liftIO $ debug $ "[Zmq|Gen] errored with something unshowable..."
    Right (Left (SomeException err)) -> liftIO $ debug $ "[Zmq|Aer] errored with: " ++ show err
    Right (Right _) -> liftIO $ debug $ "[Zmq|Aer] errored with something unshowable..."
