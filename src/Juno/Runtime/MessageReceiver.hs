{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Runtime.MessageReceiver
  ( runMessageReceiver
  , ReceiverEnv(..)
  ) where

-- import Control.Concurrent (forkIO)
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
  }
makeLenses ''ReceiverEnv

runMessageReceiver :: ReceiverEnv -> IO ()
runMessageReceiver env = void $ foreverRetry (env ^. debugPrint) "MSG_RECEIVER_TURBO" $ runReaderT messageReceiver env

-- | Thread to take incoming messages and write them to the event queue.
-- THREAD: MESSAGE RECEIVER (client and server), no state updates
messageReceiver :: ReaderT ReceiverEnv IO ()
messageReceiver = do
  env <- ask
  gm' <- view (dispatch.inboundGeneral)
  let gm n = readComms gm' n
  getCmds' <- view (dispatch.inboundCMD)
  let getCmds n = readComms getCmds' n
  getAers' <- view (dispatch.inboundAER)
  let getAers n = readComms getAers' n
  enqueueEvent' <- view (dispatch.internalEvent)
  let enqueueEvent = writeComm enqueueEvent' . InternalEvent
  debug <- view debugPrint
  -- KeySet <$> view (cfg.publicKeys) <*> view (cfg.clientPublicKeys)
  ks <- view keySet
  void $ liftIO $ foreverRetry debug "RV_AND_RVR_MSGRECVER" $ runReaderT rvAndRvrFastPath env
  liftIO $ forever $ do
    (alotOfAers, invalidAers) <- toAlotOfAers <$> getAers 2000
    unless (alotOfAers == mempty) $ enqueueEvent $ AERs alotOfAers
    mapM_ debug invalidAers
    gm 50 >>= \s -> runReaderT (sequentialVerify _unInboundGeneral ks s) env
    verifiedCmds <- parallelVerify _unInboundCMD ks <$> getCmds 5000
    (invalidCmds, validCmds) <- return $ partitionEithers verifiedCmds
    mapM_ debug invalidCmds
    cmds@(CommandBatch cmds' _) <- return $ batchCommands validCmds
    lenCmdBatch <- return $ length cmds'
    unless (lenCmdBatch == 0) $ do
      enqueueEvent $ ERPC $ CMDB' cmds
      debug $ "AutoBatched " ++ show (length cmds') ++ " Commands"

rvAndRvrFastPath :: ReaderT ReceiverEnv IO ()
rvAndRvrFastPath = do
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

toAlotOfAers :: [InboundAER] -> (AlotOfAERs, [String])
toAlotOfAers s = (alotOfAers, invalids)
  where
    (invalids, decodedAers) = partitionEithers $ uncurry (aerOnlyDecode) . _unInboundAER <$> s
    mkAlot aer@AppendEntriesResponse{..} = AlotOfAERs $ Map.insert _aerNodeId (Set.singleton aer) Map.empty
    alotOfAers = mconcat (mkAlot <$> decodedAers)


sequentialVerify :: (MonadIO m, MonadReader ReceiverEnv m)
                 => (f -> (ReceivedAt, SignedRPC)) -> KeySet -> [f] -> m ()
sequentialVerify f ks msgs = do
  (aes, noAes) <- return $ partition (\(_,SignedRPC{..}) -> if _digType _sigDigest == AE then True else False) (f <$> msgs)
  (invalid, validNoAes) <- return $ partitionEithers $ parallelVerify id ks noAes
  enqueueEvent <- view (dispatch.internalEvent)
  debug <- view debugPrint
  unless (null validNoAes) $ mapM_ (liftIO . writeComm enqueueEvent . InternalEvent . ERPC) validNoAes
  unless (null invalid) $ mapM_ (liftIO . debug) invalid
  unless (null aes) $ mapM_ (\(ts,msg) -> case signedRPCtoRPC (Just ts) ks msg of
            Left err -> liftIO $ debug err
            Right v -> liftIO $ writeComm enqueueEvent $ InternalEvent $ ERPC v) aes

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
