{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Messaging.Turbine.NewCMD
  ( newCmdTurbine
  ) where

import Control.Concurrent (threadDelay)
import Control.Lens
import Control.Monad
import Control.Monad.Reader

import Data.Either (partitionEithers)
import Data.Sequence (Seq)
import Data.Foldable (toList)

import Kadena.Types hiding (debugPrint, nodeId)
import Kadena.Messaging.Turbine.Types
import Kadena.PreProc.Types (ProcessRequestChannel(..), ProcessRequest(..))

newCmdTurbine :: ReaderT ReceiverEnv IO ()
newCmdTurbine = do
  getCmds' <- view (dispatch.inboundCMD)
  prChan <- view (dispatch.processRequestChannel)
  let getCmds n = readComms getCmds' n
  enqueueEvent' <- view (dispatch.internalEvent)
  let enqueueEvent = writeComm enqueueEvent' . InternalEvent
  debug <- view debugPrint
  ks <- view keySet
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
    mapM (verifyCmds ks' prChan) cmds' >>= return . concat
  (invalidCmds, validCmds) <- return $ partitionEithers verifiedCmds
  mapM_ debug' invalidCmds
  lenCmdBatch <- return $ length validCmds
  unless (lenCmdBatch == 0) $ do
    enqueueEvent' $ NewCmd validCmds
    debug' $ turbineCmd ++ "batched " ++ show (length validCmds) ++ " CMD(s)"
  when (lenCmdBatch > 100) $ threadDelay 500000 -- .5sec

verifyCmds :: KeySet -> ProcessRequestChannel -> InboundCMD -> IO [Either String Command]
verifyCmds ks prChan (InboundCMD (_rAt, srpc))  = case signedRPCtoRPC (Just _rAt) ks srpc of
  Left !err -> return $ [Left $ err]
  Right !(NEW' (NewCmdRPC pcmds _)) -> mapM (decodeAndInformPreProc prChan) pcmds -- (\x -> decodeCommandEither x >>= \y -> Right (rAt, y)) <$> pcmds
  Right !x -> error $! "Invariant Error: verifyCmds, encountered a non-`NEW'` SRPC in the CMD turbine: " ++ show x
verifyCmds _ prChan (InboundCMDFromApi (_rAt, NewCmdInternal{..})) = mapM (decodeAndInformPreProc prChan) _newCmdInternal -- (\x -> decodeCommandEither x >>= \y -> Right (rAt, y)) <$> _newCmdInternal
{-# INLINE verifyCmds #-}

decodeAndInformPreProc :: ProcessRequestChannel -> CMDWire -> IO (Either String Command)
decodeAndInformPreProc prChan cmdWire = do
  res <- decodeCommandEitherIO cmdWire
  case res of
    Left err -> return $ Left err
    Right (cmd, rpp) -> do
      writeComm prChan $ CommandPreProc rpp
      return $ Right cmd
