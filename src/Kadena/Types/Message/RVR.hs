{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Message.RVR
  ( RequestVoteResponse(..)
  , rvrTerm
  , rvrHeardFromLeader
  , rvrNodeId
  , voteGranted
  , rvrCandidateId
  , rvrProvenance
  , toSetRvr
  , decodeRVRWire
  , HeardFromLeader(..)
  , hflLeaderId
  , hflYourRvSig
  , hflLastLogIndex
  , hflLastLogTerm
  ) where

import Control.Lens
import qualified Crypto.Ed25519.Pure as Ed25519
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import Data.Thyme.Time.Core ()
import GHC.Generics

import Pact.Types.Hash

import Kadena.Crypto
import Kadena.Types.Base
import Kadena.Types.Message.Signed

data HeardFromLeader = HeardFromLeader
  { _hflLeaderId :: !NodeId
  , _hflYourRvSig :: !Ed25519.Signature
  , _hflLastLogIndex :: !LogIndex
  , _hflLastLogTerm :: !Term
  } deriving (Show, Eq, Ord, Generic, Serialize)
makeLenses ''HeardFromLeader

data RequestVoteResponse = RequestVoteResponse
  { _rvrTerm        :: !Term
  , _rvrHeardFromLeader :: !(Maybe HeardFromLeader)
  , _rvrNodeId      :: !NodeId
  , _voteGranted    :: !Bool
  , _rvrCandidateId :: !NodeId
  , _rvrProvenance  :: !Provenance
  }
  deriving (Show, Eq, Ord, Generic)
makeLenses ''RequestVoteResponse

data RVRWire = RVRWire (Term,Maybe HeardFromLeader,NodeId,Bool,NodeId)
  deriving (Show, Generic)
instance Serialize RVRWire

instance WireFormat RequestVoteResponse where
  toWire nid pubKey privKey RequestVoteResponse{..} = case _rvrProvenance of
    NewMsg -> let bdy = S.encode $ RVRWire (_rvrTerm,_rvrHeardFromLeader,_rvrNodeId,_voteGranted,_rvrCandidateId)
                  hsh = pactHash bdy
                  sig = sign hsh privKey pubKey
                  dig = Digest (_alias nid) sig pubKey RVR hsh
              in SignedRPC dig bdy
    ReceivedMsg{..} -> SignedRPC _pDig _pOrig
  fromWire !ts !ks s@(SignedRPC !dig !bdy) = case verifySignedRPC ks s of
    Left !err -> Left $! err
    Right () -> if _digType dig /= RVR
      then error $ "Invariant Failure: attempting to decode " ++ show (_digType dig) ++ " with RVRWire instance"
      else case S.decode bdy of
        Left !err -> Left $! "Failure to decode RVRWire: " ++ err
        Right (RVRWire !(t,li,nid,granted,cid)) -> Right $! RequestVoteResponse t li nid granted cid $ ReceivedMsg dig bdy ts
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}

-- TODO: check if `toSetRvr eRvrs = Set.fromList <$> sequence eRvrs` is fusable?
toSetRvr :: [Either String RequestVoteResponse] -> Either String (Set RequestVoteResponse)
toSetRvr eRvrs = go eRvrs Set.empty
  where
    go [] s = Right $! s
    go (Right rvr:rvrs) s = go rvrs (Set.insert rvr s)
    go (Left err:_) _ = Left $! err
{-# INLINE toSetRvr #-}

-- the expected behavior here is tricky. For a set of votes, we are actually okay if some are invalid so long as there's a quorum
-- however while we're still in alpha I think these failures represent a bug. Hence, they should be raised asap.
decodeRVRWire :: Maybe ReceivedAt -> KeySet -> [SignedRPC] -> Either String (Set RequestVoteResponse)
decodeRVRWire ts ks votes' = go votes' Set.empty
  where
    go [] s = Right $! s
    go (v:vs) s = case fromWire ts ks v of
      Left err -> Left $! err
      Right rvr' -> go vs (Set.insert rvr' s)
{-# INLINE decodeRVRWire #-}
