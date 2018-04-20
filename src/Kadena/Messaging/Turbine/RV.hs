
module Kadena.Messaging.Turbine.RV
  ( rvAndRvrTurbine
  ) where

-- TODO: we use toList to change from a Seq to a list for `parList`, change this


import Control.Lens
import Control.Monad
import Control.Monad.Reader

import Kadena.Types hiding (debugPrint, nodeId)
import Kadena.Messaging.Turbine.Types

rvAndRvrTurbine :: ReaderT ReceiverEnv IO ()
rvAndRvrTurbine = do
  getRvAndRVRs' <- view (dispatch.inboundRVorRVR)
  enqueueEvent <- view (dispatch.consensusEvent)
  debug <- view debugPrint
  ks <- view keySet
  liftIO $ forever $ do
    (ts, msg) <- _unInboundRVorRVR <$> readComm getRvAndRVRs'
    case signedRPCtoRPC (Just ts) ks msg of
      Left err -> debug err
      Right v -> do
        debug $ turbineRv ++ "received " ++ show (_digType $ _sigDigest msg)
        writeComm enqueueEvent $ ConsensusEvent $ ERPC v
