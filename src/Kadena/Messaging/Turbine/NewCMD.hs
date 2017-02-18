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
import qualified Data.Set as Set

import Kadena.Types hiding (debugPrint, nodeId)
import Kadena.Messaging.Turbine.Types

cmdTurbine :: ReaderT ReceiverEnv IO ()
cmdTurbine = do
  getCmds' <- view (dispatch.inboundCMD)
  let getCmds n = readComms getCmds' n
  enqueueEvent' <- view (dispatch.internalEvent)
  let enqueueEvent = writeComm enqueueEvent' . InternalEvent
  debug <- view debugPrint
  ks <- view keySet
  liftIO $ cmdDynamicTurbine ks getCmds debug enqueueEvent

cmdDynamicTurbine
  :: Num a =>
     KeySet
     -> (a -> IO (Seq InboundCMD))
     -> (String -> IO ())
     -> (Event -> IO ())
     -> IO ()
cmdDynamicTurbine ks' getCmds' debug' enqueueEvent' = forever $ do
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
  when (lenCmdBatch > 100) $ threadDelay 500000 -- .5sec

batchCommands :: [RPC] -> CommandBatch
batchCommands cmdRPCs = cmdBatch
  where
    cmdBatch = CommandBatch (Commands $! concat (prepCmds <$> cmdRPCs)) NewMsg
    prepCmds (CMD' cmd) = [cmd]
    prepCmds (CMDB' (CommandBatch (Commands cmds) _)) = cmds
    prepCmds o = error $ "Invariant failure in batchCommands: pattern match failure " ++ show o
{-# INLINE batchCommands #-}
