{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Kadena.Messaging.Turbine.NewCMD
  ( newCmdTurbine
  ) where

import Control.Lens
import Control.Monad
import Control.Monad.Reader

import Data.Either (partitionEithers)
import Data.Sequence (Seq)
import Data.Foldable (toList)
import Data.Thyme.Clock (getCurrentTime)

import Kadena.Command
import Kadena.Crypto
import Kadena.Types hiding (debugPrint)
import Kadena.Message
import Kadena.Messaging.Turbine.Util
import Kadena.Types.PreProc (ProcessRequestChannel(..), ProcessRequest(..))

newCmdTurbine :: ReaderT ReceiverEnv IO ()
newCmdTurbine = do
  getCmds' <- view (turbineDispatch . dispInboundCMD)
  prChan <- view (turbineDispatch . dispProcessRequestChannel)
  let getCmds n = readComms getCmds' n
  enqueueEvent' <- view (turbineDispatch . dispConsensusEvent)
  let enqueueEvent = writeComm enqueueEvent' . ConsensusEvent
  debug <- view turbineDebugPrint
  ks <- view turbineKeySet
  liftIO $ newCmdDynamicTurbine ks getCmds debug enqueueEvent prChan

newCmdDynamicTurbine
  :: Num a =>
     KeySet
     -> (a -> IO (Seq InboundCMD))
     -> (String -> IO ())
     -> (Event -> IO ())
     -> ProcessRequestChannel
     -> IO ()
newCmdDynamicTurbine ks' getCmds' debug' enqueueEvent' prChan= forever $ do
  verifiedCmds <- do
    cmds' <- toList <$> getCmds' 5000
    concat <$> mapM (verifyCmds ks' prChan) cmds'
  (invalidCmds, validCmds) <- return $ partitionEithers verifiedCmds
  mapM_ debug' invalidCmds
  lenCmdBatch <- return $ length validCmds
  unless (lenCmdBatch == 0) $ do
    enqueueEvent' $ NewCmd validCmds
    debug' $ turbineCmd ++ "batched " ++ show (length validCmds) ++ " CMD(s)"

-- TODO: do this better, right now we just use the first message for making the metrics
mkCmdLatMetric :: ReceivedAt -> IO (Maybe CmdLatencyMetrics)
mkCmdLatMetric rAt = do
  now' <- getCurrentTime
  lat' <- return $! initCmdLat $ Just $ rAt
  return $ populateCmdLat lmHitTurbine now' lat'

verifyCmds :: KeySet -> ProcessRequestChannel -> InboundCMD -> IO [Either String (Maybe CmdLatencyMetrics, Command)]
verifyCmds ks prChan (InboundCMD (rAt, srpc))  = case signedRPCtoRPC (Just rAt) ks srpc of
  Left !err -> return $ [Left $ err]
  Right !(NEW' (NewCmdRPC pcmds _)) -> do
    lat' <- mkCmdLatMetric rAt
    cmds' <- mapM (decodeAndInformPreProc prChan) pcmds -- (\x -> decodeCommandEither x >>= \y -> Right (rAt, y)) <$> pcmds
    return $ fmap (fmap (lat',)) cmds'
  Right !x -> error $! "Invariant Error: verifyCmds, encountered a non-`NEW'` SRPC in the CMD turbine: " ++ show x
verifyCmds _ prChan (InboundCMDFromApi (rAt, NewCmdInternal{..})) = do
  lat' <- mkCmdLatMetric rAt
  cmds' <- mapM (decodeAndInformPreProc prChan) _newCmdInternal -- (\x -> decodeCommandEither x >>= \y -> Right (rAt, y)) <$> _newCmdInternal
  return $ fmap (fmap (lat',)) cmds'
{-# INLINE verifyCmds #-}

decodeAndInformPreProc :: ProcessRequestChannel -> CMDWire -> IO (Either String Command)
decodeAndInformPreProc prChan cmdWire = do
  res <- decodeCommandEitherIO cmdWire
  case res of
    Left err -> return $ Left err
    Right (cmd, rpp) -> case rpp of
      Just rpp' -> do
        writeComm prChan $ CommandPreProc rpp'
        return $! Right cmd
      Nothing -> return $! Right cmd
