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

newCmdTurbine :: ReaderT ReceiverEnv IO ()
newCmdTurbine = do
  getCmds' <- view (dispatch.inboundCMD)
  let getCmds n = readComms getCmds' n
  enqueueEvent' <- view (dispatch.internalEvent)
  let enqueueEvent = writeComm enqueueEvent' . InternalEvent
  debug <- view debugPrint
  ks <- view keySet
  liftIO $ newCmdDynamicTurbine ks getCmds debug enqueueEvent

newCmdDynamicTurbine
  :: Num a =>
     KeySet
     -> (a -> IO (Seq InboundCMD))
     -> (String -> IO ())
     -> (Event -> IO ())
     -> IO ()
newCmdDynamicTurbine ks' getCmds' debug' enqueueEvent' = forever $ do
  verifiedCmds <- do
    cmds' <- toList <$> getCmds' 5000
    return $! concat $! verifyCmds ks' <$> cmds'
  (invalidCmds, validCmds) <- return $ partitionEithers verifiedCmds
  mapM_ debug' invalidCmds
  lenCmdBatch <- return $ length validCmds
  unless (lenCmdBatch == 0) $ do
    enqueueEvent' $ NewCmd validCmds
    debug' $ turbineCmd ++ "batched " ++ show (length validCmds) ++ " CMD(s)"
  when (lenCmdBatch > 100) $ threadDelay 500000 -- .5sec

verifyCmds :: KeySet -> InboundCMD -> [Either String Command]
verifyCmds ks (InboundCMD (_rAt, srpc)) = case signedRPCtoRPC (Just _rAt) ks srpc of
  Left !err -> [Left $ err]
  Right !(NEW' (NewCmdRPC pcmds _)) -> decodeCommandEither <$> pcmds -- (\x -> decodeCommandEither x >>= \y -> Right (rAt, y)) <$> pcmds
  Right !x -> error $! "Invariant Error: verifyCmds, encountered a non-`NEW'` SRPC in the CMD turbine: " ++ show x
verifyCmds _ (InboundCMDFromApi (_rAt, NewCmdInternal{..})) = decodeCommandEither <$> _newCmdInternal -- (\x -> decodeCommandEither x >>= \y -> Right (rAt, y)) <$> _newCmdInternal
{-# INLINE verifyCmds #-}
