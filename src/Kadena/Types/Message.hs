{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.Types.Message
  ( module X
  , RPC(..)
  , signedRPCtoRPC, rpcToSignedRPC
  , Topic(..)
  , Envelope(..)
  , sealEnvelope, openEnvelope
  , InboundCMD(..)
  , InboundCMDChannel(..)
  , OutboundGeneral(..)
  , OutboundGeneralChannel(..)
  , broadcastMsg, directMsg
  ) where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty(..))
import GHC.Generics
import Data.Typeable (Typeable)
import Control.Concurrent.Chan (Chan)
import Data.Sequence (Seq)
import Control.Concurrent.STM.TVar (TVar)

import Kadena.Types.Base
import Kadena.Types.Config
import Kadena.Types.Comms

import Kadena.Types.Message.AE as X
import Kadena.Types.Message.AER as X
import Kadena.Types.Message.NewCMD as X
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
         | NEW'  NewCmdRPC -- NB: this should never go in ERPC as an internal event, use NewCmd
  deriving (Show, Eq, Generic)

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



data InboundCMD =
  InboundCMD
  { _unInboundCMD :: (ReceivedAt, SignedRPC)} |
  InboundCMDFromApi
  { _unInboundCMDFromApi :: (ReceivedAt, NewCmdInternal)}
  deriving (Show, Eq, Typeable)


newtype OutboundGeneral = OutboundGeneral { _unOutboundGeneral :: [Envelope]}
  deriving (Show, Eq, Typeable)

directMsg :: [(NodeId, ByteString)] -> OutboundGeneral
directMsg msgs = OutboundGeneral $! Envelope . (\(n,b) -> (Topic $ unAlias $ _alias n, b)) <$> msgs

broadcastMsg :: [ByteString] -> OutboundGeneral
broadcastMsg msgs = OutboundGeneral $! Envelope . (\b -> (Topic $ "all", b)) <$> msgs


newtype InboundCMDChannel = InboundCMDChannel (Chan InboundCMD, TVar (Seq InboundCMD))


newtype OutboundGeneralChannel = OutboundGeneralChannel (Chan OutboundGeneral)


instance Comms InboundCMD InboundCMDChannel where
  initComms = InboundCMDChannel <$> initCommsBatched
  readComm (InboundCMDChannel (_,m))  = readCommBatched m
  writeComm (InboundCMDChannel (c,_)) = writeCommBatched c
  {-# INLINE initComms #-}
  {-# INLINE readComm #-}
  {-# INLINE writeComm #-}

instance BatchedComms InboundCMD InboundCMDChannel where
  readComms (InboundCMDChannel (_,m)) cnt = readCommsBatched m cnt
  {-# INLINE readComms #-}
  writeComms (InboundCMDChannel (_,m)) xs = writeCommsBatched m xs
  {-# INLINE writeComms #-}


instance Comms OutboundGeneral OutboundGeneralChannel where
  initComms = OutboundGeneralChannel <$> initCommsNormal
  readComm (OutboundGeneralChannel c) = readCommNormal c
  writeComm (OutboundGeneralChannel c) = writeCommNormal c
  {-# INLINE initComms #-}
  {-# INLINE readComm #-}
  {-# INLINE writeComm #-}
