{-# LANGUAGE TemplateHaskell #-}

module Kadena.Messaging.Turbine.Types
  ( ReceiverEnv(..), dispatch, keySet, debugPrint, restartTurbo
  , turbineRv, turbineAer, turbineCmd, turbineGeneral
  , parallelVerify
  , parSeqToList
  , processMsg
  ) where

import Control.Concurrent (MVar)
import Control.Lens
import Control.Parallel.Strategies

import Data.Sequence (Seq)
import qualified Data.Sequence as Seq

import Kadena.Message
import Kadena.Types hiding (debugPrint, nodeId)

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

parallelVerify :: (f -> (ReceivedAt,SignedRPC)) -> KeySet -> Seq f -> [Either String RPC]
parallelVerify f ks msgs = runEval $ parSeqToList (processMsg f ks) msgs

parSeqToList :: (f -> Either String RPC) -> Seq f -> Eval [Either String RPC]
parSeqToList f s = do
  case Seq.viewl s of
    Seq.EmptyL -> return []
    x Seq.:< xs -> do
      res <- rpar (f x)
      (res:) <$> parSeqToList f xs

processMsg :: (f -> (ReceivedAt,SignedRPC)) -> KeySet -> (f -> Either String RPC)
processMsg f ks = (\(ts, msg) -> signedRPCtoRPC (Just ts) ks msg) . f
