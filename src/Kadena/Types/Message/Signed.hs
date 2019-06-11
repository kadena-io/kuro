{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Message.Signed
  ( MsgType(..)
  , Provenance(..), pDig, pOrig, pTimeStamp
  , Digest(..), digNodeId, digSig, digPubkey, digType, digHash
  , SignedRPC(..)
  -- for testing & benchmarks
  , verifySignedRPC, verifySignedRPCNoReHash
  , WireFormat(..)
  , DeserializationError(..)
  ) where

import Control.Exception
import Control.Lens hiding (Index)
import Control.Parallel.Strategies
import Data.Typeable

import qualified Data.Map as Map
import Data.ByteString (ByteString)
import Data.Serialize (Serialize)
import Data.Thyme.Time.Core ()
import GHC.Generics

import Kadena.Types.Base
import Kadena.Types.KeySet

import Pact.Types.Scheme (PPKScheme(..), SPPKScheme)

-- | One way or another we need a way to figure our what set of public keys to use for verification of signatures.
-- By placing the message type in the digest, we can make the WireFormat implementation easier as well. CMD and REV
-- need to use the Client Public Key maps.
data MsgType = AE | AER | RV | RVR | NEW
  deriving (Show, Eq, Ord, Generic)
instance Serialize MsgType

-- | Digest containing Sender ID, Signature, Sender's Public Key and the message type
data Digest = Digest
  { _digNodeId :: !Alias
  , _digSig    :: !(Signature (SPPKScheme 'ED25519))
  , _digPubkey :: !(PublicKey (SPPKScheme 'ED25519))
  , _digType   :: !MsgType
  , _digHash   :: !Hash
  } deriving (Show, Eq, Ord, Generic)
makeLenses ''Digest

instance Serialize Digest

-- | Provenance is used to track if we made the message or received it. This is important for re-transmission.
data Provenance =
  NewMsg |
  ReceivedMsg
    { _pDig :: !Digest
    , _pOrig :: !ByteString
    , _pTimeStamp :: !(Maybe ReceivedAt)
    } deriving (Show, Eq, Ord, Generic)
-- instance Serialize Provenance <== This is bait, if you uncomment it you've done something wrong
-- We really want to be sure that Provenance from one Node isn't by accident transferred to another node.
-- Without a Serialize instance, we can be REALLY sure.
makeLenses ''Provenance

-- | Type that is serialized and sent over the wire
data SignedRPC = SignedRPC
  { _sigDigest :: !Digest
  , _sigBody   :: !ByteString
  } deriving (Show, Eq, Generic)
instance Serialize SignedRPC

class WireFormat a s | a -> s where
  toWire   :: NodeId -> PublicKey s -> PrivateKey s -> a -> SignedRPC
  fromWire :: Maybe ReceivedAt -> KeySet s -> SignedRPC -> Either String a

newtype DeserializationError = DeserializationError String deriving (Show, Eq, Typeable)

instance Exception DeserializationError

-- | Based on the MsgType in the SignedRPC's Digest, choose the keySet to try to find the key in
pickKey :: KeySet s -> SignedRPC -> Either String (PublicKey s)
pickKey !KeySet{..} sRpc@(SignedRPC !Digest{..} _) =
  case Map.lookup _digNodeId _ksCluster of
    Nothing -> Left $! "PubKey not found for NodeId: " ++ show _digNodeId
    Just !key
      | key /= _digPubkey -> Left $! "Public key in storage doesn't match digest's key for msg: " ++ show sRpc
      | otherwise -> Right $! key
{-# INLINE pickKey #-}

verifySignedRPC :: KeySet s -> SignedRPC -> Either String ()
verifySignedRPC ks s = pickKey ks s >>= rehashAndVerify s
{-# INLINE verifySignedRPC #-}

verifySignedRPCNoReHash :: KeySet s -> SignedRPC -> Either String ()
verifySignedRPCNoReHash ks s = pickKey ks s >>= verifyNoHash s
{-# INLINE verifySignedRPCNoReHash #-}

rehashAndVerify :: SignedRPC -> PublicKey s -> Either String ()
rehashAndVerify s@(SignedRPC !Digest{..} !bdy) !key = runEval $ do
  h <- rpar $ hash bdy
  c <- rpar $ valid _digHash key _digSig
  hashRes <- rseq h
  if hashRes /= _digHash
  then return $! Left $! "Unable to verify SignedRPC hash: "
              ++ " our=" ++ show hashRes
              ++ " theirs=" ++ show _digHash
              ++ " in " ++ show s
  else do
    cryptoRes <- rseq c
    if not cryptoRes
    then return $! Left $! "Unable to verify SignedRPC sig: " ++ show s
    else return $! Right ()
{-# INLINE rehashAndVerify #-}

verifyNoHash :: SignedRPC -> PublicKey s -> Either String ()
verifyNoHash s@(SignedRPC !Digest{..} _) key =
  if not $ valid _digHash key _digSig
  then Left $! "Unable to verify SignedRPC sig: " ++ show s
  else Right ()
{-# INLINE verifyNoHash #-}
