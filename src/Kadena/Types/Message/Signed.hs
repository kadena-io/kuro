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
  ) where

import Control.Exception
import Control.Lens hiding (Index)
import Control.Parallel.Strategies
import qualified Crypto.PubKey.Ed25519 as Ed25519

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

data Digest s = Digest
  { _digNodeId :: !Alias
  , _digSig    :: !(Signature s)
  , _digPubkey :: !(PublicKey s)
  , _digType   :: !MsgType
  , _digHash   :: !Hash
  } deriving (Generic)
makeLenses ''Digest
instance (Scheme a, Serialize (Signature a), Serialize (PublicKey a))=> Serialize (Digest a)

type ShowScheme a = (Show a, Show (Signature a), Show (PublicKey a), Show (PrivateKey a))
-- ^ all the Show constraints to avoid repeating the gigantic signature...
instance ShowScheme a => Show (Digest a)

-- | Provenance is used to track if we made the message or received it. This is important for
--   re-transmission.
data Provenance a =
  NewMsg |
  ReceivedMsg
    { _pDig :: !(Digest a)
    , _pOrig :: !ByteString
    , _pTimeStamp :: !(Maybe ReceivedAt)
    } deriving (Generic)
-- instance Serialize Provenance <== This is bait, if you uncomment it you've done something wrong
-- We really want to be sure that Provenance from one Node isn't by accident transferred to another
-- node. Without a Serialize instance, we can be REALLY sure.
makeLenses ''Provenance

-- | Type that is serialized and sent over the wire
data SignedRPC a = SignedRPC
  { _sigDigest :: !(Digest a)
  , _sigBody   :: !ByteString
  } deriving (Generic)
instance (Scheme a, Serialize (Digest a)) => Serialize (SignedRPC a)
instance (Show a, Show (Digest a)) => Show (SignedRPC a)

class WireFormat a s | a -> s where
  toWire   :: NodeId -> PublicKey s -> PrivateKey s -> a -> SignedRPC s
  fromWire :: Maybe ReceivedAt -> KeySet s -> SignedRPC s -> Either String a

newtype DeserializationError = DeserializationError String deriving (Show, Eq, Typeable)

instance Exception DeserializationError

-- | Based on the MsgType in the SignedRPC's Digest, choose the keySet to try to find the key in
-- pickKey :: (Scheme s, Show s, Show (Signature s), Show (PublicKey s)) => KeySet s -> SignedRPC s -> Either String (PCrypto.PublicKey s)
pickKey :: (Scheme s, ShowScheme s) => KeySet s -> SignedRPC s -> Either String (PCrypto.PublicKey s)
pickKey !KeySet{..} sRpc@(SignedRPC !Digest{..} _) =
  case Map.lookup _digNodeId _ksCluster of
    Nothing -> Left $! "PubKey not found for NodeId: " ++ show _digNodeId
    Just !key
      | key /= _digPubkey -> Left $! "Public key in storage doesn't match digest's key for msg: "
                                     ++ show sRpc
      | otherwise -> Right $! key
{-# INLINE pickKey #-}

-- verifySignedRPC :: (Scheme s, Show s, Show (Signature s), Show (PublicKey s)) => KeySet s -> SignedRPC s -> Either String ()
verifySignedRPC :: (Scheme s, ShowScheme s) => KeySet s -> SignedRPC s -> Either String ()
verifySignedRPC ks signed = pickKey ks signed >>= rehashAndVerify signed
{-# INLINE verifySignedRPC #-}

verifySignedRPCNoReHash :: (Scheme s, ShowScheme s) => KeySet s -> SignedRPC s -> Either String ()
verifySignedRPCNoReHash ks s = pickKey ks s >>= verifyNoHash s
{-# INLINE verifySignedRPCNoReHash #-}

rehashAndVerify :: Scheme s => SignedRPC s -> PublicKey s -> Either String ()
rehashAndVerify signed@(SignedRPC !Digest{..} !bdy) !key = runEval $ do
  -- h <- rpar $ hash bdy
  h <- rpar $ pactHash bdy
  -- c <- rpar $ valid _digHash key _digSig
  c <- rpar $ verify defaultScheme _digHash (PublicKeyBS key) _digSig
  hashRes <- rseq h
  if hashRes /= _digHash
  then return $! Left $! "Unable to verify SignedRPC hash: "
              ++ " our=" ++ show hashRes
              ++ " theirs=" ++ show _digHash
              ++ " in " ++ show signed
  else do
    cryptoRes <- rseq c
    if not cryptoRes
    then return $! Left $! "Unable to verify SignedRPC sig: " ++ show signed
    else return $! Right ()
{-# INLINE rehashAndVerify #-}

verifyNoHash :: SignedRPC s -> PublicKey s -> Either String ()
verifyNoHash s@(SignedRPC !Digest{..} _) key =
  if not $ valid _digHash key _digSig
  then Left $! "Unable to verify SignedRPC sig: " ++ show s
  else Right ()
{-# INLINE verifyNoHash #-}
