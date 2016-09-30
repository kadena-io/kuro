{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Runtime.MessageReceiver
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

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set

import Data.Thyme.Clock (getCurrentTime)

import Kadena.Util.Combinator (foreverRetry)
import Kadena.Types hiding (debugPrint, nodeId)
import Kadena.Types.Evidence (Evidence(VerifiedAER))

data ReceiverEnv = ReceiverEnv
  { _dispatch :: Dispatch
  , _keySet :: KeySet
  , _debugPrint :: String -> IO ()
  , _restartTurbo :: MVar String
  }
makeLenses ''ReceiverEnv

turbineRv, turbineAer, turbineCmd, turbineGeneral :: String
turbineRv = "[Turbine|Rv]: "
turbineAer = "[Turbine|Aer]: "
turbineCmd = "[Turbine|Cmd]: "
turbineGeneral = "[Turbine|Gen]: "

runMessageReceiver :: ReceiverEnv -> IO ()
runMessageReceiver env = void $ foreverRetry (env ^. debugPrint) "[Turbo|MsgReceiver]" $ runReaderT messageReceiver env

-- | Thread to take incoming messages and write them to the event queue.
-- THREAD: MESSAGE RECEIVER (client and server), no state updates
messageReceiver :: ReaderT ReceiverEnv IO ()
messageReceiver = do
  env <- ask
  debug <- view debugPrint
  void $ liftIO $ foreverRetry debug turbineRv $ runReaderT rvAndRvrTurbine env
  void $ liftIO $ foreverRetry debug turbineAer $ runReaderT aerTurbine env
  void $ liftIO $ foreverRetry debug turbineCmd $ runReaderT cmdTurbine env
  void $ liftIO $ foreverRetry debug turbineGeneral $ runReaderT generalTurbine env
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
    msgs <- gm 10
    (aes, noAes) <- return $ partition (\(_,SignedRPC{..}) -> if _digType _sigDigest == AE then True else False) (_unInboundGeneral <$> msgs)
    prunedAes <- return $ pruneRedundantAEs aes
    when (length aes - length prunedAes /= 0) $ debug $ turbineGeneral ++ "pruned " ++ show (length aes - length prunedAes) ++ " redundant AE(s)"
    unless (null aes) $ do
      l <- return $ show (length aes)
      mapM_ (\(ts,msg) -> case signedRPCtoRPC (Just ts) ks msg of
        Left err -> debug err
        Right v -> do
          t' <- getCurrentTime
          debug $ turbineGeneral ++ "enqueued 1 of " ++ l ++ " AE(s) taking "
                ++ show (interval (_unReceivedAt ts) t')
                ++ "mics since it was received"
          enqueueEvent (ERPC v)
            ) prunedAes
    (invalid, validNoAes) <- return $ partitionEithers $ parallelVerify id ks noAes
    unless (null validNoAes) $ mapM_ (enqueueEvent . ERPC) validNoAes
    unless (null invalid) $ mapM_ debug invalid

-- just a quick hack until we get better logic for sending AE's.
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
  lenCmdBatch <- return $ length $ unCommands cmds'
  unless (lenCmdBatch == 0) $ do
    enqueueEvent' $ ERPC $ CMDB' cmds
    src <- return (Set.fromList $ fmap (\v' -> case v' of
      CMD' v -> ( unAlias $ _cmdClientId v, unAlias $ _digNodeId $ _pDig $ _cmdProvenance v )
      CMDB' v -> ( "CMDB", unAlias $ _digNodeId $ _pDig $ _cmdbProvenance v )
      v -> error $ "deep invariant failure: caught something that wasn't a CMDB/CMD " ++ show v
      ) validCmds)
    debug' $ turbineCmd ++ "batched " ++ show (length $ unCommands cmds') ++ " CMD(s) from " ++ show src
  threadDelay timeout
  case lenCmdBatch of
    l | l > 1000  -> cmdDynamicTurbine ks' getCmds' debug' enqueueEvent' 1000000 -- 1sec
      | l > 500   -> cmdDynamicTurbine ks' getCmds' debug' enqueueEvent' 500000 -- .5sec
      | l > 100   -> cmdDynamicTurbine ks' getCmds' debug' enqueueEvent' 100000 -- .1sec
      | l > 10    -> cmdDynamicTurbine ks' getCmds' debug' enqueueEvent' 50000 -- .05sec
      | otherwise -> cmdDynamicTurbine ks' getCmds' debug' enqueueEvent' 10000 -- .01sec

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
        debug $ turbineRv ++ "received " ++ show (_digType $ _sigDigest msg)
        writeComm enqueueEvent $ InternalEvent $ ERPC v

parallelVerify :: (f -> (ReceivedAt,SignedRPC)) -> KeySet -> [f] -> [Either String RPC]
parallelVerify f ks msgs = ((\(ts, msg) -> signedRPCtoRPC (Just ts) ks msg) . f <$> msgs) `using` parList rseq

batchCommands :: [RPC] -> CommandBatch
batchCommands cmdRPCs = cmdBatch
  where
    cmdBatch = CommandBatch (Commands $! concat (prepCmds <$> cmdRPCs)) NewMsg
    prepCmds (CMD' cmd) = [cmd]
    prepCmds (CMDB' (CommandBatch (Commands cmds) _)) = cmds
    prepCmds o = error $ "Invariant failure in batchCommands: " ++ show o
{-# INLINE batchCommands #-}

aerTurbine :: ReaderT ReceiverEnv IO ()
aerTurbine = do
  getAers' <- view (dispatch.inboundAER)
  let getAers n = readComms getAers' n
  enqueueEvent' <- view (dispatch.evidence)
  let enqueueEvent = writeComm enqueueEvent' . VerifiedAER
  debug <- view debugPrint
  ks <- view keySet
  let backpressureDelay = 500
  forever $ liftIO $ do
    -- basically get every AER
    rawAers <- getAers 2000
    if null rawAers
    -- give it some time to build up redundant pieces of evidence
    then threadDelay backpressureDelay
    else do
      startTime <- getCurrentTime
      (invalidAers, unverifiedAers) <- return $! constructEvidenceMap rawAers
      (badCrypto, validAers) <- return $! partitionEithers $! ((getFirstValidAer ks <$> (Map.elems unverifiedAers)) `using` parList rseq)
      enqueueEvent validAers
      mapM_ (debug . ((++) turbineAer)) invalidAers
      mapM_ (debug . ((++) turbineAer)) $ concat badCrypto
      endTime <- getCurrentTime
      timeDelta <- return $! interval startTime endTime
      debug $ turbineAer ++ "received " ++ show (length rawAers) ++ " AER(s) & processed them into the "
            ++ show (length validAers) ++ " AER(s) taking " ++ show timeDelta ++ "mics"
      -- I think keeping the delay relatively constant is a good idea
      unless (timeDelta >= (fromIntegral $ backpressureDelay)) $ threadDelay (backpressureDelay - (fromIntegral $ timeDelta))

constructEvidenceMap :: [InboundAER] -> ([String], Map NodeId (Set AppendEntriesResponse))
constructEvidenceMap srpcs = go srpcs Map.empty []
  where
    go [] m errs = (errs,m)
    go (InboundAER (ts,srpc):rest) m errs = case aerDecodeNoVerify (ts, srpc) of
      Left err -> go rest m (err:errs)
      Right aer -> go rest (Map.insertWith Set.union (_aerNodeId aer) (Set.singleton aer) m) errs
{-# INLINE constructEvidenceMap #-}

getFirstValidAer :: KeySet -> Set AppendEntriesResponse -> Either [String] AppendEntriesResponse
getFirstValidAer ks sAer = go (Set.toDescList sAer) []
  where
    go [] errs = Left errs
    go (aer:rest) errs = case aerReverify ks aer of
      Left err -> go rest (err:errs)
      Right aer' -> Right aer'
{-# INLINE getFirstValidAer #-}
