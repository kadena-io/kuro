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

import Data.AffineSpace ((.-.))
import Data.Thyme.Clock (microseconds, getCurrentTime)

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
    msgs <- gm 5
    (aes, noAes) <- return $ partition (\(_,SignedRPC{..}) -> if _digType _sigDigest == AE then True else False) (_unInboundGeneral <$> msgs)
    prunedAes <- return $ pruneRedundantAEs aes
    when (length aes - length prunedAes /= 0) $ debug $ "[GENERAL_TURBINE] pruned " ++ show (length aes - length prunedAes) ++ " redundant AE(s)"
    unless (null aes) $ do
      l <- return $ show (length aes)
      mapM_ (\(ts,msg) -> case signedRPCtoRPC (Just ts) ks msg of
        Left err -> debug err
        Right v -> do
          t' <- getCurrentTime
          debug $ "[GENERAL_TURBINE] enqueued 1 of " ++ l ++ " AE(s) taking "
                ++ show (view microseconds $ t' .-. (_unReceivedAt ts))
                ++ "mics since it was received"
          enqueueEvent (ERPC v)
            ) prunedAes
    (invalid, validNoAes) <- return $ partitionEithers $ parallelVerify id ks noAes
    unless (null validNoAes) $ mapM_ (enqueueEvent . ERPC) validNoAes
    unless (null invalid) $ mapM_ debug invalid

-- just a quick hack until we get better logic for sending AE's.
-- The idea is that the leader may send us the same AE a few times and as they are an expensive operation we'd prefer to avoid redundant crypto
-- TODO: figure out if there's a way for the leader to optimize traffic without risking elections
pruneRedundantAEs :: [(ReceivedAt, SignedRPC)] -> [(ReceivedAt, SignedRPC)]
pruneRedundantAEs m = go m Set.empty
  where
    getSig = _digSig . _sigDigest . snd
    go [] _ = []
    go [ae] s = if Set.member (getSig ae) s then [] else [ae]
    go (ae:aes) s = if Set.member (getSig ae) s then go aes (Set.insert (getSig ae) s) else ae : go aes (Set.insert (getSig ae) s)

cmdTurbine :: ReaderT ReceiverEnv IO ()
cmdTurbine = do
  getCmds' <- view (dispatch.inboundCMD)
  let getCmds n = readComms getCmds' n
  enqueueEvent' <- view (dispatch.internalEvent)
  let enqueueEvent = writeComm enqueueEvent' . InternalEvent
  debug <- view debugPrint
  ks <- view keySet
  liftIO $ cmdDynamicTurbine ks getCmds debug enqueueEvent 10000

cmdDynamicTurbine
  :: Num a =>
     KeySet
     -> (a -> IO [InboundCMD])
     -> (String -> IO ())
     -> (Event -> IO ())
     -> Int
     -> IO b
cmdDynamicTurbine ks' getCmds' debug' enqueueEvent' timeout = do
  verifiedCmds <- parallelVerify _unInboundCMD ks' <$> getCmds' 5000
  (invalidCmds, validCmds) <- return $ partitionEithers verifiedCmds
  mapM_ debug' invalidCmds
  cmds@(CommandBatch cmds' _) <- return $ batchCommands validCmds
  lenCmdBatch <- return $ length cmds'
  unless (lenCmdBatch == 0) $ do
    enqueueEvent' $ ERPC $ CMDB' cmds
    src <- return (Set.fromList $ fmap (\v' -> case v' of
      CMD' v -> ( unAlias $ _alias $ _cmdClientId v, unAlias $ _alias $ _digNodeId $ _pDig $ _cmdProvenance v )
      CMDB' v -> ( "CMDB", unAlias $ _alias $ _digNodeId $ _pDig $ _cmdbProvenance v )
      v -> error $ "deep invariant failure: caught something that wasn't a CMDB/CMD " ++ show v
      ) validCmds)
    debug' $ "AutoBatched " ++ show (length cmds') ++ " Commands from " ++ show src
  threadDelay timeout
  case lenCmdBatch of
    l | l > 1000  -> cmdDynamicTurbine ks' getCmds' debug' enqueueEvent' 1000000 -- 1sec
      | l > 500   -> cmdDynamicTurbine ks' getCmds' debug' enqueueEvent' 500000 -- .5sec
      | l > 100   -> cmdDynamicTurbine ks' getCmds' debug' enqueueEvent' 100000 -- .1sec
      | l > 10    -> cmdDynamicTurbine ks' getCmds' debug' enqueueEvent' 50000 -- .05sec
      | otherwise -> cmdDynamicTurbine ks' getCmds' debug' enqueueEvent' 10000 -- .01sec



aerTurbine :: ReaderT ReceiverEnv IO ()
aerTurbine = do
  getAers' <- view (dispatch.inboundAER)
  let getAers n = readComms getAers' n
  enqueueEvent' <- view (dispatch.internalEvent)
  let enqueueEvent = writeComm enqueueEvent' . InternalEvent
  debug <- view debugPrint
  ks <- view keySet
  forever $ liftIO $ do
    (alotOfAers, invalidAers) <- toAlotOfAers ks <$> getAers 2000
    unless (alotOfAers == mempty) $ enqueueEvent $ AERs alotOfAers
    mapM_ debug invalidAers
    threadDelay 10000 -- 10ms delay for AERs

toAlotOfAers :: KeySet -> [InboundAER] -> (AlotOfAERs, [String])
toAlotOfAers ks s = (alotOfAers, invalids)
  where
    (invalids, decodedAers) = partitionEithers $ parallelVerify _unInboundAER ks s
    mkAlot (AER' aer@AppendEntriesResponse{..}) = AlotOfAERs $ Map.insert _aerNodeId (Set.singleton aer) Map.empty
    mkAlot msg = error $ "invariant error: expected AER' but got " ++ show msg
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
