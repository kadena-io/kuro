{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module Kadena.Types.Message.Signed
  ( Provenance(..), pDig, pOrig, pTimeStamp
  , Digest(..), digNodeId, digSig, digPubkey, digType, digHash
  , MsgType(..)
  , SignedRPC(..)
  -- for testing & benchmarks
  , verifySignedRPC, verifySignedRPCNoReHash
  , WireFormat(..)
  , DeserializationError(..)
  ) where

import Control.Exception
import Control.Lens hiding (Index)
import Control.Parallel.Strategies

import qualified Crypto.Ed25519.Pure as Ed25519

import qualified Data.Map as Map
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import qualified Crypto.Error as E
import qualified Data.ByteString as BS
import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import Data.Thyme.Time.Core ()
import Data.Typeable
import GHC.Generics

import Kadena.Crypto
import Kadena.Types.Base

import Pact.Types.Hash

-- | One way or another we need a way to figure our what set of public keys to use for verification
--   of signatures. By placing the message type in the digest, we can make the WireFormat
--   implementation easier as well. CMD and REV need to use the Client Public Key maps.
data MsgType = AE | AER | RV | RVR | NEW
  deriving (Show, Eq, Ord, Generic)
instance Serialize MsgType

data Digest = Digest
  { _digNodeId :: !Alias
  , _digSig    :: !Ed25519.Signature
  , _digPubkey :: !Ed25519.PublicKey
  , _digType   :: !MsgType
  , _digHash   :: !Hash
  } deriving (Show, Eq, Ord, Serialize, Generic)
makeLenses ''Digest

-- | Provenance is used to track if we made the message or received it. This is important for
--   re-transmission.
data Provenance =
  NewMsg |
  ReceivedMsg
    { _pDig :: !Digest
    , _pOrig :: !ByteString
    , _pTimeStamp :: !(Maybe ReceivedAt)
    } deriving (Show, Eq, Ord, Generic)
-- instance Serialize Provenance <== This is bait, if you uncomment it you've done something wrong
-- We really want to be sure that Provenance from one Node isn't by accident transferred to another
-- node. Without a Serialize instance, we can be REALLY sure.
makeLenses ''Provenance

-- | Type that is serialized and sent over the wire
data SignedRPC = SignedRPC
  { _sigDigest :: !Digest
  , _sigBody   :: !ByteString
  } deriving (Eq, Show, Serialize, Generic)

class WireFormat a where
  toWire   :: NodeId -> Ed25519.PublicKey -> Ed25519.PrivateKey -> a -> SignedRPC
  fromWire :: Maybe ReceivedAt -> KeySet -> SignedRPC -> Either String a

newtype DeserializationError = DeserializationError String deriving (Show, Eq, Typeable)

instance Exception DeserializationError

-- | Based on the MsgType in the SignedRPC's Digest, choose the keySet to try to find the key in
pickKey :: KeySet -> SignedRPC -> Either String Ed25519.PublicKey
pickKey !KeySet{..} sRpc@(SignedRPC !Digest{..} _) =
  case Map.lookup _digNodeId _ksCluster of
    Nothing -> Left $! "PubKey not found for NodeId: " ++ show _digNodeId
    Just !key
      | key /= _digPubkey -> Left $! "Public key in storage doesn't match digest's key for msg: "
                                     ++ show sRpc
      | otherwise -> Right $! key
{-# INLINE pickKey #-}

verifySignedRPC :: KeySet -> SignedRPC -> Either String ()
verifySignedRPC ks signed = pickKey ks signed >>= rehashAndVerify signed
{-# INLINE verifySignedRPC #-}

verifySignedRPCNoReHash :: KeySet -> SignedRPC -> Either String ()
verifySignedRPCNoReHash ks s = pickKey ks s >>= verifyNoHash s
{-# INLINE verifySignedRPCNoReHash #-}

rehashAndVerify :: SignedRPC -> Ed25519.PublicKey -> Either String ()
rehashAndVerify s@(SignedRPC !Digest{..} !bdy) !key = runEval $ do
  h <- rpar $ pactHash bdy
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

verifyNoHash :: SignedRPC -> Ed25519.PublicKey -> Either String ()
verifyNoHash s@(SignedRPC !Digest{..} _) key =
  if not $ valid _digHash key _digSig
  then Left $! "Unable to verify SignedRPC sig: " ++ show s
  else Right ()
{-# INLINE verifyNoHash #-}
