module Kadena.Messaging.Turbine.RV
  ( rvAndRvrTurbine
  ) where

-- TODO: we use toList to change from a Seq to a list for `parList`, change this


import Control.Lens
import Control.Monad
import Control.Monad.Reader

import Kadena.Message (signedRPCtoRPC)
import Kadena.Types.Event (Event(..), ConsensusEvent(..))
import Kadena.Types.Message.Signed (SignedRPC(..), Digest(..))
import Kadena.Types.Comms (InboundRVorRVR(..), Comms(..))
import Kadena.Types.Dispatch (dispInboundRVorRVR, dispConsensusEvent)
import Kadena.Types.Turbine (ReceiverEnv(..), turbineDebugPrint, turbineKeySet, turbineDebugPrint, turbineDispatch)
import Kadena.Messaging.Turbine.Util

rvAndRvrTurbine :: ReaderT ReceiverEnv IO ()
rvAndRvrTurbine = do
  getRvAndRVRs' <- view (turbineDispatch . dispInboundRVorRVR)
  enqueueEvent <- view (turbineDispatch . dispConsensusEvent)
  debug <- view turbineDebugPrint
  ks <- view turbineKeySet
  liftIO $ forever $ do
    (ts, msg) <- _unInboundRVorRVR <$> readComm getRvAndRVRs'
    case signedRPCtoRPC (Just ts) ks msg of
      Left err -> debug err
      Right v -> do
        debug $ turbineRv ++ "received " ++ show (_digType $ _sigDigest msg)
        writeComm enqueueEvent $ ConsensusEvent $ ERPC v
