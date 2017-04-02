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
import Control.Concurrent (yield, newEmptyMVar, takeMVar, putMVar)
import qualified Control.Concurrent.Async as Async
import Control.Monad.State.Strict
import System.ZMQ4.Monadic
import Data.Thyme.Clock
import Data.Serialize

import Kadena.Types
import Kadena.Util.Util (catchAndRethrow)

nodeIdToZmqAddr :: NodeId -> String
nodeIdToZmqAddr NodeId{..} = "tcp://" ++ _host ++ ":" ++ show _port

zmqLinkedAsync :: String -> ZMQ z a -> ZMQ z ()
zmqLinkedAsync loc fn = do
  a <- async $ catchAndRethrow loc fn
  liftIO $ Async.link a

zmqPub, zmqSub :: String
zmqPub = "[Zmq|Pub]: "
zmqSub = "[Zmq|Sub]: "

runMsgServer :: Dispatch
             -> NodeId
             -> [NodeId]
             -> (String -> IO ())
             -> IO ()
runMsgServer dispatch me addrList debug = forever $ do
  inboxWrite <- return $ dispatch ^. inboundGeneral
  cmdInboxWrite <- return $ dispatch ^. inboundCMD
  aerInboxWrite <- return $ dispatch ^. inboundAER
  rvAndRvrWrite <- return $ dispatch ^. inboundRVorRVR
  outboxRead <- return $ dispatch ^. outboundGeneral

  semephory <- newEmptyMVar -- this MVar is for coordinating the lighting of ZMQ. There's an annoying segfault/malloc error that I think is caused by ZMQ.

  runZMQ $ do
    -- ZMQ Pub Thread
    zmqLinkedAsync "ZmqPub" $ do
      liftIO $ debug $ zmqPub ++ "launch!"
      pubSock <- socket Pub
      _ <- bind pubSock $ nodeIdToZmqAddr me
      liftIO $ putMVar semephory ()
      forever $ do
        !msgs <- liftIO (_unOutboundGeneral <$> readComm outboxRead) >>= return . fmap sealEnvelope
        startTime <- liftIO getCurrentTime
        mapM_ (sendMulti pubSock) msgs
        endTime <- liftIO getCurrentTime
        liftIO $ debug $ zmqPub ++ "publishing msg " ++ (printInterval startTime endTime)

    liftIO $ void $ takeMVar semephory

    subSocket <- socket Sub
    subscribe subSocket "all" -- the topic for broadcast messages
    liftIO $ debug $ zmqSub ++ "subscribed to: \"all\""
    subscribe subSocket $ unAlias $ _alias me
    liftIO $ debug $ zmqSub ++ "subscribed to: " ++ show (unAlias $ _alias me)
    void $ mapM_ (\addr -> do
        _ <- connect subSocket $ nodeIdToZmqAddr $ addr
        liftIO $ debug $  zmqSub ++ "made sub socket for: " ++ (show $ nodeIdToZmqAddr addr )
        ) addrList
    liftIO $ putMVar semephory ()
    forever $ do
      env <- openEnvelope <$> receiveMulti subSocket
      ts <- liftIO getCurrentTime
      case env of
        Left err ->
          liftIO $ debug $  zmqSub ++ show err
        Right (Envelope (_topic',newMsg)) -> do
          liftIO $ debug $  zmqSub ++ "got msg on topic: " ++ show (_unTopic _topic')
          case decode newMsg of
            Left err -> do
              liftIO $ debug $ zmqSub ++ "failed to deserialize to SignedRPC [Msg]: " ++ show newMsg
              liftIO $ debug $ zmqSub ++ "failed to deserialize to SignedRPC [Error]: " ++ err
              liftIO yield
            Right s@(SignedRPC dig _)
              | _digType dig == RV || _digType dig == RVR -> do
                endTime <- liftIO getCurrentTime
                liftIO $ writeComm rvAndRvrWrite (InboundRVorRVR (ReceivedAt ts, s)) >> yield
                liftIO $ debug $ zmqSub ++ " Received RVR from: " ++ (show $ _digNodeId dig) ++ " " ++ printInterval ts endTime
              | _digType dig == NEW -> do
                endTime <- liftIO getCurrentTime
                liftIO $ writeComm cmdInboxWrite (InboundCMD (ReceivedAt ts, s)) >> yield
                liftIO $ debug $ zmqSub ++ " Received NEW from: " ++ (show $ _digNodeId dig) ++ " " ++ printInterval ts endTime
              | _digType dig == AER -> do
                endTime <- liftIO getCurrentTime
                liftIO $ writeComm aerInboxWrite (InboundAER (ReceivedAt ts, s)) >> yield
                liftIO $ debug $ zmqSub ++ " Received AER from: " ++ (show $ _digNodeId dig) ++ " " ++ printInterval ts endTime
              | otherwise           -> do
                endTime <- liftIO getCurrentTime
                liftIO $ writeComm inboxWrite (InboundGeneral (ReceivedAt ts, s)) >> yield
                liftIO $ debug $ zmqSub ++ " Received " ++ (show $ _digType dig) ++ " from " ++ (show $ _digNodeId dig) ++ " " ++ printInterval ts endTime
