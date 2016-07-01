{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Runtime.MessageReceiver
  ( runMessageReceiver
  , ReceiverEnv(..), dispatch, keySet, debugPrint, restartTurbo
  ) where

import Control.Concurrent (threadDelay, MVar, takeMVar)
import Control.Lens
import Control.Monad
import Control.Monad.Reader
import Control.Parallel.Strategies
import Data.Either (partitionEithers)
import Data.List (partition)
import qualified Data.Map.Strict as Map
import qualified Data.Serialize as S
import qualified Data.Set as Set

import Juno.Util.Combinator (foreverRetry)
import Juno.Types hiding (debugPrint, nodeId)

data ReceiverEnv = ReceiverEnv
  { _dispatch :: Dispatch
  , _keySet :: KeySet
  , _debugPrint :: String -> IO ()
  , _restartTurbo :: MVar String
  }
makeLenses ''ReceiverEnv

runMessageReceiver :: ReceiverEnv -> IO ()
runMessageReceiver env = void $ foreverRetry (env ^. debugPrint) "MSG_RECEIVER_TURBO" $ runReaderT messageReceiver env

-- | Thread to take incoming messages and write them to the event queue.
-- THREAD: MESSAGE RECEIVER (client and server), no state updates
messageReceiver :: ReaderT ReceiverEnv IO ()
messageReceiver = do
  env <- ask
  debug <- view debugPrint
  void $ liftIO $ foreverRetry debug "RV_AND_RVR_TURBINE" $ runReaderT rvAndRvrTurbine env
  void $ liftIO $ foreverRetry debug "AER_TURBINE" $ runReaderT aerTurbine env
  void $ liftIO $ foreverRetry debug "CMD_TURBINE" $ runReaderT cmdTurbine env
  void $ liftIO $ foreverRetry debug "GENERAL_TURBINE" $ runReaderT generalTurbine env
  liftIO $ takeMVar (_restartTurbo env) >>= debug . (++) "restartTurbo MVar caught saying: "

generalTurbine :: ReaderT ReceiverEnv IO ()
generalTurbine = do
  gm' <- view (dispatch.inboundGeneral)
  let gm n = readComms gm' n
  enqueueEvent' <- view (dispatch.internalEvent)
  let enqueueEvent = writeComm enqueueEvent' . InternalEvent
  debug <- view debugPrint
  ks <- view keySet
  forever $ liftIO $ do
    msgs <- gm 50
    (aes, noAes) <- return $ partition (\(_,SignedRPC{..}) -> if _digType _sigDigest == AE then True else False) (_unInboundGeneral <$> msgs)
    (invalid, validNoAes) <- return $ partitionEithers $ parallelVerify id ks noAes
    unless (null validNoAes) $ mapM_ (liftIO . enqueueEvent . ERPC) validNoAes
    unless (null invalid) $ mapM_ (liftIO . debug) invalid
    unless (null aes) $ mapM_ (\(ts,msg) -> case signedRPCtoRPC (Just ts) ks msg of
              Left err -> liftIO $ debug err
              Right v -> liftIO $ enqueueEvent $ ERPC v) aes

cmdTurbine :: ReaderT ReceiverEnv IO ()
cmdTurbine = do
  getCmds' <- view (dispatch.inboundCMD)
  let getCmds n = readComms getCmds' n
  enqueueEvent' <- view (dispatch.internalEvent)
  let enqueueEvent = writeComm enqueueEvent' . InternalEvent
  debug <- view debugPrint
  ks <- view keySet
  forever $ liftIO $ do
    verifiedCmds <- parallelVerify _unInboundCMD ks <$> getCmds 5000
    (invalidCmds, validCmds) <- return $ partitionEithers verifiedCmds
    mapM_ debug invalidCmds
    cmds@(CommandBatch cmds' _) <- return $ batchCommands validCmds
    lenCmdBatch <- return $ length cmds'
    unless (lenCmdBatch == 0) $ do
      enqueueEvent $ ERPC $ CMDB' cmds
      debug $ "AutoBatched " ++ show (length cmds') ++ " Commands"
      threadDelay 100000 -- 100ms delay

aerTurbine :: ReaderT ReceiverEnv IO ()
aerTurbine = do
  getAers' <- view (dispatch.inboundAER)
  let getAers n = readComms getAers' n
  enqueueEvent' <- view (dispatch.internalEvent)
  let enqueueEvent = writeComm enqueueEvent' . InternalEvent
  debug <- view debugPrint
  forever $ liftIO $ do
    (alotOfAers, invalidAers) <- toAlotOfAers <$> getAers 2000
    unless (alotOfAers == mempty) $ enqueueEvent $ AERs alotOfAers
    mapM_ debug invalidAers
    threadDelay 10000 -- 10ms delay for AERs

toAlotOfAers :: [InboundAER] -> (AlotOfAERs, [String])
toAlotOfAers s = (alotOfAers, invalids)
  where
    (invalids, decodedAers) = partitionEithers $ uncurry (aerOnlyDecode) . _unInboundAER <$> s
    mkAlot aer@AppendEntriesResponse{..} = AlotOfAERs $ Map.insert _aerNodeId (Set.singleton aer) Map.empty
    alotOfAers = mconcat (mkAlot <$> decodedAers)

rvAndRvrTurbine :: ReaderT ReceiverEnv IO ()
rvAndRvrTurbine = do
  getRvAndRVRs' <- view (dispatch.inboundRVorRVR)
  enqueueEvent <- view (dispatch.internalEvent)
  debug <- view debugPrint
  ks <- view keySet
  liftIO $ forever $ do
    (ts, msg) <- _unInboundRVorRVR <$> readComm getRvAndRVRs'
    case signedRPCtoRPC (Just ts) ks msg of
      Left err -> debug err
      Right v -> do
        debug $ "Received " ++ show (_digType $ _sigDigest msg)
        writeComm enqueueEvent $ InternalEvent $ ERPC v

parallelVerify :: (f -> (ReceivedAt,SignedRPC)) -> KeySet -> [f] -> [Either String RPC]
parallelVerify f ks msgs = ((\(ts, msg) -> signedRPCtoRPC (Just ts) ks msg) . f <$> msgs) `using` parList rseq


batchCommands :: [RPC] -> CommandBatch
batchCommands cmdRPCs = cmdBatch
  where
    cmdBatch = CommandBatch (concat (prepCmds <$> cmdRPCs)) NewMsg
    prepCmds (CMD' cmd) = [cmd]
    prepCmds (CMDB' (CommandBatch cmds _)) = cmds
    prepCmds o = error $ "Invariant failure in batchCommands: " ++ show o


aerOnlyDecode :: ReceivedAt -> SignedRPC -> Either String AppendEntriesResponse
aerOnlyDecode ts s@SignedRPC{..}
  | _digType _sigDigest /= AER = error $ "Invariant Error: aerOnlyDecode called on " ++ show s
  | otherwise = case S.decode _sigBody of
      Left !err -> Left $! "Failure to decode AERWire: " ++ err
      Right (AERWire !(t,nid,s',c,i,h)) -> Right $! AppendEntriesResponse t nid s' c i h False $ ReceivedMsg _sigDigest _sigBody $ Just ts
