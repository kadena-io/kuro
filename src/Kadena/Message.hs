{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.Message
  ( signedRPCtoRPC, rpcToSignedRPC
  , sealEnvelope, openEnvelope
  , broadcastMsg, directMsg
  ) where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty(..))

import Kadena.Types.Base
import Kadena.Types.Config
import Kadena.Types.Message

sealEnvelope :: Envelope -> NonEmpty ByteString
sealEnvelope (Envelope (Topic t, msg)) = t :| [msg]

openEnvelope :: [ByteString] -> Either String Envelope
openEnvelope [] = Left "Cannot open envelope: Empty list"
openEnvelope [t,msg] = Right $ Envelope (Topic t,msg)
openEnvelope e = Left $ "Cannot open envelope: too many elements in list (expected 2, got "
                        ++ show (length e)
                        ++ ")\n### Raw Envelope ###"
                        ++ show e

signedRPCtoRPC :: Maybe ReceivedAt -> KeySet -> SignedRPC -> Either String RPC
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ AE _)   _) = (\rpc -> rpc `seq` AE'   rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ AER _)  _) = (\rpc -> rpc `seq` AER'  rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ RV _)   _) = (\rpc -> rpc `seq` RV'   rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ RVR _)  _) = (\rpc -> rpc `seq` RVR'  rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ NEW _)  _) = (\rpc -> rpc `seq` NEW'  rpc) <$> fromWire ts ks s
{-# INLINE signedRPCtoRPC #-}

rpcToSignedRPC :: NodeId -> PublicKey -> PrivateKey -> RPC -> SignedRPC
rpcToSignedRPC nid pubKey privKey (AE' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (AER' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (RV' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (RVR' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (NEW' v) = toWire nid pubKey privKey v
{-# INLINE rpcToSignedRPC #-}

directMsg :: [(NodeId, ByteString)] -> OutboundGeneral
directMsg msgs = OutboundGeneral $! Envelope . (\(n,b) -> (Topic $ unAlias $ _alias n, b)) <$> msgs

broadcastMsg :: [ByteString] -> OutboundGeneral
broadcastMsg msgs = OutboundGeneral $! Envelope . (\b -> (Topic $ "all", b)) <$> msgs