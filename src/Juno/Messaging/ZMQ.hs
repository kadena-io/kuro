{-# LANGUAGE ScopedTypeVariables #-}
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
import Data.Thyme.Calendar (showGregorian)
import Data.Thyme.LocalTime
import System.IO (hFlush, stderr, stdout)

import Juno.Types
-- import Juno.Util.Combinator (foreverRetry)

sendProcess :: OutChan OutboundGeneral
            -> Rolodex String (Socket z Push)
            -> ZMQ z ()
sendProcess outChan' !r = do
  -- liftIO $ moreLogging "Entered sendProcess"
  rMvar <- liftIO $ newMVar r
  forever $ do
    (OutBoundMsg !addrs !msg) <- liftIO $! _unOutboundGeneral <$> readComm outChan'
    -- liftIO $ moreLogging $ "Sending message to " ++ (show addrs) ++ " ## MSG ## " ++ show msg
    r' <- liftIO $ takeMVar rMvar
    !newRol <- updateRolodex r' addrs
    !toPoll <- recipList newRol addrs
    mapM_ (\s -> send s [] msg) toPoll
    liftIO $ putMVar rMvar newRol
    -- liftIO $ moreLogging "Sent Msg"

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

moreLogging :: String -> IO ()
moreLogging msg = do
  (ZonedTime (LocalTime d' t') _) <- getZonedTime
  putStrLn $ (showGregorian d') ++ "T" ++ (take 15 $ show t') ++ " [ZMQ]: " ++ msg
  hFlush stdout >> hFlush stderr


runMsgServer :: Dispatch
             -> Addr String
             -> [Addr String]
             -> IO ()
runMsgServer dispatch me addrList = void $ forkIO $ forever $ do
  inboxWrite <- return $ inChan $ dispatch ^. inboundGeneral
  cmdInboxWrite <- return $ inChan $ dispatch ^. inboundCMD
  aerInboxWrite <- return $ inChan $ dispatch ^. inboundAER
  rvAndRvrWrite <- return $ inChan $ dispatch ^. inboundRVorRVR
  outboxRead <- return $ outChan $ dispatch ^. outboundGeneral

  zmqThread <- Async.async $ runZMQ $ do
    -- liftIO $ moreLogging "Launching ZMQ_THREAD"
    zmqReceiver <- async $ do
      -- liftIO $ moreLogging "Launching ZMQ_RECEIVER"
      sock <- socket Pull
      _ <- bind sock $ _unAddr me
      forever $ do
        newMsg <- receive sock
        ts <- liftIO getCurrentTime
        case decode newMsg of
          Left err -> do
            liftIO $ moreLogging $ "Failed to deserialize to SignedRPC [Msg]: " ++ show newMsg
            liftIO $ moreLogging $ "Failed to deserialize to SignedRPC [Error]: " ++ err
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
    liftIO $ threadDelay 100000 -- to be sure that the receive side is up first

    -- liftIO $ moreLogging "Launching ZMQ_SENDER"
    zmqSender <- async $ do
      rolodex <- addNewAddrs (Rolodex Map.empty) addrList
      void $ sendProcess outboxRead rolodex
      -- liftIO $ moreLogging "Exiting ZMQ_SENDER"
    liftIO $ (Async.waitEitherCancel zmqReceiver zmqSender) >>= \res' -> case res' of
      Left () -> liftIO $ moreLogging "ZMQ_RECEIVER returned with ()"
      Right v -> liftIO $ moreLogging $ "ZMQ_SENDER returned with " ++ show v
    liftIO $ moreLogging "Exiting ZMQ_THREAD"
  res <- Async.waitCatch zmqThread
  Async.cancel zmqThread >> case res of
    Right () -> moreLogging "ZMQ_MSG_SERVER died returning () with no details"
    Left err -> moreLogging $ "ZMQ_MSG_SERVER exception " ++ show err
