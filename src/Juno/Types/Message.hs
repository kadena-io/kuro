{-# LANGUAGE DeriveGeneric #-}

module Juno.Types.Message
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

import Juno.Types.Base
import Juno.Types.Config

import Juno.Types.Message.AE as X
import Juno.Types.Message.AER as X
import Juno.Types.Message.CMD as X
import Juno.Types.Message.CMDR as X
import Juno.Types.Message.REV as X
import Juno.Types.Message.RV as X
import Juno.Types.Message.RVR as X
import Juno.Types.Message.Signed as X

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
         | REV'  Revolution
  deriving (Show, Eq, Generic)

signedRPCtoRPC :: Maybe ReceivedAt -> KeySet -> SignedRPC -> Either String RPC
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ AE)   _) = (\rpc -> rpc `seq` AE'   rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ AER)  _) = (\rpc -> rpc `seq` AER'  rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ RV)   _) = (\rpc -> rpc `seq` RV'   rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ RVR)  _) = (\rpc -> rpc `seq` RVR'  rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ CMD)  _) = (\rpc -> rpc `seq` CMD'  rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ CMDR) _) = (\rpc -> rpc `seq` CMDR' rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ CMDB) _) = (\rpc -> rpc `seq` CMDB' rpc) <$> fromWire ts ks s
signedRPCtoRPC ts ks s@(SignedRPC (Digest _ _ _ REV)  _) = (\rpc -> rpc `seq` REV'  rpc) <$> fromWire ts ks s
{-# INLINE signedRPCtoRPC #-}

rpcToSignedRPC :: NodeId -> PublicKey -> PrivateKey -> RPC -> SignedRPC
rpcToSignedRPC nid pubKey privKey (AE' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (AER' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (RV' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (RVR' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (CMD' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (CMDR' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (CMDB' v) = toWire nid pubKey privKey v
rpcToSignedRPC nid pubKey privKey (REV' v) = toWire nid pubKey privKey v
{-# INLINE rpcToSignedRPC #-}
