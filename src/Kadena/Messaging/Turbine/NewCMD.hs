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
  verifiedCmds <- parallelVerify _unInboundCMD ks' <$> getCmds' 5000
  (invalidCmds, validCmds) <- return $ partitionEithers verifiedCmds
  mapM_ debug' invalidCmds
  cmdInt@(NewCmdInternal cmds) <- return $ toNewCmdInternal validCmds
  lenCmdBatch <- return $ length cmds
  unless (lenCmdBatch == 0) $ do
    enqueueEvent' $ NewCmd cmdInt
    debug' $ turbineCmd ++ "batched " ++ show (length cmds) ++ " CMD(s)"
  when (lenCmdBatch > 100) $ threadDelay 500000 -- .5sec

toNewCmdInternal :: [RPC] -> NewCmdInternal
toNewCmdInternal cmdRPCs = NewCmdInternal $! concat $! getCmds <$> cmdRPCs
  where
    getCmds (NEW' NewCmdRPC{..}) = _newCmd
    getCmds o = error $ "Invariant failure in toNewCmdInternal: pattern match failure " ++ show o
{-# INLINE toNewCmdInternal #-}
