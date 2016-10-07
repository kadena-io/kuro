{-# LANGUAGE DeriveGeneric #-}

module Kadena.Types.Message
  ( module X
  , RPC(..)
  , signedRPCtoRPC, rpcToSignedRPC
  , Topic(..)
  , Envelope(..)
  , sealEnvelope, openEnvelope
  ) where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty(..))
import GHC.Generics

import Kadena.Types.Base
import Kadena.Types.Config

import Kadena.Types.Message.AE as X
import Kadena.Types.Message.AER as X
import Kadena.Types.Message.CMD as X
import Kadena.Types.Message.CMDR as X
import Kadena.Types.Message.RV as X
import Kadena.Types.Message.RVR as X
import Kadena.Types.Message.Signed as X

newtype Topic = Topic {_unTopic :: ByteString}
  deriving (Show, Eq)
newtype Envelope = Envelope { _unOutBoundMsg :: (Topic, ByteString) }
  deriving (Show, Eq)

sealEnvelope :: Envelope -> NonEmpty ByteString
sealEnvelope (Envelope (Topic t, msg)) = t :| [msg]

openEnvelope :: [ByteString] -> Either String Envelope
openEnvelope [] = Left "Cannot open envelope: Empty list"
openEnvelope [t,msg] = Right $ Envelope (Topic t,msg)
openEnvelope e = Left $ "Cannot open envelope: too many elements in list (expected 2, got "
                        ++ show (length e)
                        ++ ")\n### Raw Envelope ###"
                        ++ show e

data RPC = AE'   AppendEntries
         | AER'  AppendEntriesResponse
         | RV'   RequestVote
         | RVR'  RequestVoteResponse
         | CMD'  Command
         | CMDB' CommandBatch
         | CMDR' CommandResponse
  deriving (Show, Eq, Generic)

signedRPCtoRPC :: Maybe ReceivedAt -> KeySet -> SignedRPC -> Either String RPC
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ AE _)   _) = (\rpc -> rpc `seq` AE'   rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ AER _)  _) = (\rpc -> rpc `seq` AER'  rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ RV _)   _) = (\rpc -> rpc `seq` RV'   rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ RVR _)  _) = (\rpc -> rpc `seq` RVR'  rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ CMD _)  _) = (\rpc -> rpc `seq` CMD'  rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ CMDR _) _) = (\rpc -> rpc `seq` CMDR' rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ CMDB _) _) = (\rpc -> rpc `seq` CMDB' rpc) <$> fromWire ts ks s
{-# INLINE signedRPCtoRPC #-}

rpcToSignedRPC :: NodeId -> PublicKey -> PrivateKey -> RPC -> SignedRPC
rpcToSignedRPC nid pubKey privKey (AE' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (AER' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (RV' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (RVR' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (CMD' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (CMDR' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (CMDB' v) = toWire nid pubKey privKey v
{-# INLINE rpcToSignedRPC #-}
