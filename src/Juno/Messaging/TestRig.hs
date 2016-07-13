{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE BangPatterns #-}

module Juno.Messaging.TestRig (
  runTestMsgServer
  ) where

import Control.Lens
import Control.Exception.Base
import Control.Concurrent (forkIO, threadDelay, yield)
import qualified Control.Concurrent.Async as Async
import Control.Monad.State.Strict
import Data.Thyme.Clock
import Data.Serialize

import Juno.Types


-- | TestMsgServer is used with the TestRig. Basically we mock the entire codepath from receive to send but yank out ZMQ
runTestMsgServer :: TestRigInputChannel
                 -> TestRigOutputChannel
                 -> Dispatch
                 -> (String -> IO ())
                 -> IO ()
runTestMsgServer testRigInput testRigOutput dispatch debug = void $ forkIO $ forever $ do
  inboxWrite <- return $ dispatch ^. inboundGeneral
  cmdInboxWrite <- return $ dispatch ^. inboundCMD
  aerInboxWrite <- return $ dispatch ^. inboundAER
  rvAndRvrWrite <- return $ dispatch ^. inboundRVorRVR
  outboxRead <- return $ dispatch ^. outboundGeneral
  aerRvRvrRead <- return $ dispatch ^. outboundAerRvRvr

  zmqGeneralThread <- Async.async $ do
    zmqPub <- Async.async $ do
      liftIO $ debug "[TESTRIG_MSGR_GENERAL_PUB] Launching..."
      forever $ do
        !msg <- liftIO $! _unOutboundGeneral <$> readComm outboxRead
        --liftIO $ debug $ "[TESTRIG_MSGR_GENERAL_PUB] publishing msg to: " ++ show (NonEmpty.head msg)
        liftIO $ writeComm testRigOutput $ TestRigOutput msg

    Async.link zmqPub
    liftIO $ threadDelay 100000 -- to be sure that the receive side is up first

    zmqSub <- Async.async $ do
      forever $ do
        env <- openEnvelope . _unTestRigInput <$> readComm testRigInput
        ts <- liftIO getCurrentTime
        case env of
          Left err ->
            liftIO $ debug $ "[TESTRIG_MSGR_GENERAL_SUB] " ++ show err
          Right (Envelope (_topic',newMsg)) -> do
            --liftIO $ debug $ "[TESTRIG_MSGR_GENERAL_SUB] got msg on topic: " ++ show (_unTopic topic')
            case decode newMsg of
              Left err -> do
                liftIO $ debug $ "[TESTRIG_MSGR_GENERAL_SUB] Failed to deserialize to SignedRPC [Msg]: " ++ show newMsg
                liftIO $ debug $ "[TESTRIG_MSGR_GENERAL_SUB] Failed to deserialize to SignedRPC [Error]: " ++ err
                liftIO yield
              Right s@(SignedRPC dig _)
                | _digType dig == RV || _digType dig == RVR -> do
                  --liftIO $ debug $ "[TESTRIG_MSGR_GENERAL_SUB] Received RVR from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm rvAndRvrWrite (InboundRVorRVR (ReceivedAt ts, s)) >> yield
                | _digType dig == CMD || _digType dig == CMDB -> do
                  --liftIO $ debug $ "[TESTRIG_MSGR_GENERAL_SUB] Received CMD or CMDB from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm cmdInboxWrite (InboundCMD (ReceivedAt ts, s)) >> yield
                | _digType dig == AER -> do
                  --liftIO $ debug $ "[TESTRIG_MSGR_GENERAL_SUB] Received AER from: " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm aerInboxWrite (InboundAER (ReceivedAt ts, s)) >> yield
                | otherwise           -> do
                  --liftIO $ debug $ "[TESTRIG_MSGR_GENERAL_SUB] Received " ++ (show $ _digType dig) ++ " from " ++ (show $ _alias $ _digNodeId dig)
                  liftIO $ writeComm inboxWrite (InboundGeneral (ReceivedAt ts, s)) >> yield

    Async.link zmqSub

    liftIO $ debug $ "[TESTRIG_MSGR_AeRvRvr_PUB] Launching..."
    void $ forever $ do
      !msg <- liftIO $! _unOutboundAerRvRvr <$> readComm aerRvRvrRead
      --liftIO $ debug $ "[TESTRIG_MSGR_AerRvRvr_PUB] publishing msg to: " ++ show (NonEmpty.head msg)
      liftIO $ writeComm testRigOutput $ TestRigOutput msg

    return $ Right ()

  liftIO $ do
    res <- Async.waitCatch zmqGeneralThread
    case res of
      Left (SomeException err) -> liftIO $ debug $ "[TESTRIG_MSGR_PUB] errored with: " ++ show err
      Right _ -> liftIO $ debug $ "[TESTRIG_MSGR_PUB] errored with something unshowable..."
  liftIO $ debug $ "[TESTRIG_MSGR_THREAD] Exiting"
