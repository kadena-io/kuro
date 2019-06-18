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
  ( MsgType(..)
  , Provenance(..), pDig, pOrig, pTimeStamp
  , Digest(..), digNodeId, digSig, digPubkey, digType, digHash
  , SignedRPC(..)
  -- for testing & benchmarks
  , verifySignedRPC, verifySignedRPCNoReHash
  , WireFormat(..)
  , DeserializationError(..)
  , MsgKeySet(..)
  , MsgPrivateKey(..)
  , MsgPublicKey(..)
  , msgSign
  , MsgSignature
  ) where

import Control.Exception
import Control.Lens hiding (Index)
import Control.Parallel.Strategies
-- import qualified Crypto.PubKey.Ed25519 as Ed25519

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
import qualified Crypto.Ed25519.Pure as Ed25519

import Kadena.Types.Base
import Kadena.Types.KeySet

import qualified Pact.Types.Crypto as PCrypto (PublicKey, PrivateKey, Signature)
import Pact.Types.Crypto
import Pact.Types.Hash
import Pact.Types.Scheme (PPKScheme(..), SPPKScheme)

-- | One way or another we need a way to figure our what set of public keys to use for verification
--   of signatures. By placing the message type in the digest, we can make the WireFormat
--   implementation easier as well. CMD and REV need to use the Client Public Key maps.
data MsgType = AE | AER | RV | RVR | NEW
  deriving (Show, Eq, Ord, Generic)
instance Serialize MsgType

type ConsensusScheme = SPPKScheme 'ED25519
type MsgSignature = Signature ConsensusScheme
type MsgPublicKey = PublicKey ConsensusScheme
type MsgPrivateKey = PrivateKey ConsensusScheme
type MsgKeySet = KeySet ConsensusScheme
type MsgKeyPair = KeyPair ConsensusScheme

msgValid :: Hash -> MsgPublicKey -> MsgSignature -> Bool
msgValid (Hash msg) pub sig = Ed25519.valid msg pub sig

msgSign :: Hash -> MsgPrivateKey -> MsgPublicKey -> MsgSignature
msgSign (Hash msg) priv pub = Ed25519.sign msg priv pub

data Digest = Digest
  { _digNodeId :: !Alias
  , _digSig    :: !MsgSignature
  , _digPubkey :: !MsgPublicKey
  , _digType   :: !MsgType
  , _digHash   :: !Hash
  } deriving (Show, Eq, Ord, Serialize, Generic)
makeLenses ''Digest

-- type ShowScheme a = (Show a, Show (Signature a), Show (PublicKey a), Show (PrivateKey a))
-- ^ all the Show constraints to avoid repeating the gigantic signature...
-- instance ShowScheme a => Show (Digest a)

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
  } deriving (Show, Serialize, Generic)

class WireFormat a where
  toWire   :: NodeId -> MsgPublicKey -> MsgPrivateKey -> a -> SignedRPC
  fromWire :: Maybe ReceivedAt -> MsgKeySet -> SignedRPC -> Either String a

newtype DeserializationError = DeserializationError String deriving (Show, Eq, Typeable)

instance Exception DeserializationError

-- | Based on the MsgType in the SignedRPC's Digest, choose the keySet to try to find the key in
pickKey :: MsgKeySet -> SignedRPC -> Either String MsgPublicKey
pickKey !KeySet{..} sRpc@(SignedRPC !Digest{..} _) =
  case Map.lookup _digNodeId _ksCluster of
    Nothing -> Left $! "PubKey not found for NodeId: " ++ show _digNodeId
    Just !key
      | key /= _digPubkey -> Left $! "Public key in storage doesn't match digest's key for msg: "
                                     ++ show sRpc
      | otherwise -> Right $! key
{-# INLINE pickKey #-}

verifySignedRPC :: MsgKeySet -> SignedRPC -> Either String ()
verifySignedRPC ks signed = pickKey ks signed >>= rehashAndVerify signed
{-# INLINE verifySignedRPC #-}

verifySignedRPCNoReHash :: MsgKeySet -> SignedRPC -> Either String ()
verifySignedRPCNoReHash ks s = pickKey ks s >>= verifyNoHash s
{-# INLINE verifySignedRPCNoReHash #-}

rehashAndVerify :: SignedRPC -> MsgPublicKey -> Either String ()
rehashAndVerify s@(SignedRPC !Digest{..} !bdy) !key = runEval $ do
  h <- rpar $ pactHash bdy
  c <- rpar $ msgValid _digHash key _digSig

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

verifyNoHash :: SignedRPC -> MsgPublicKey -> Either String ()
verifyNoHash s@(SignedRPC !Digest{..} _) key =
  if not $ msgValid _digHash key _digSig
  then Left $! "Unable to verify SignedRPC sig: " ++ show s
  else Right ()
{-# INLINE verifyNoHash #-}
