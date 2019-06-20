{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Message.RV
  ( RequestVote(..), rvTerm, rvCandidateId, rvLastLogIndex, rvLastLogTerm, rvProvenance
  ) where

import Control.Lens
import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import Data.Thyme.Time.Core ()
import GHC.Generics

import Pact.Types.Hash

import Kadena.Crypto
import Kadena.Types.Base
import Kadena.Types.Message.Signed

data RequestVote = RequestVote
  { _rvTerm        :: !Term
  , _rvCandidateId :: !NodeId -- Sender ID Right? We don't forward RV's
  , _rvLastLogIndex  :: !LogIndex
  , _rvLastLogTerm   :: !Term
  , _rvProvenance  :: !Provenance
  }
  deriving (Show, Eq, Generic)
makeLenses ''RequestVote

data RVWire = RVWire (Term,NodeId,LogIndex,Term)
  deriving (Show, Generic)
instance Serialize RVWire

instance WireFormat RequestVote where
  toWire nid pubKey privKey RequestVote{..} = case _rvProvenance of
    NewMsg -> let bdy = S.encode $ RVWire ( _rvTerm
                                          , _rvCandidateId
                                          , _rvLastLogIndex
                                          , _rvLastLogTerm)
                  hsh = pactHash bdy
                  sig = sign hsh privKey pubKey
                  dig = Digest (_alias nid) sig pubKey RV hsh
              in SignedRPC dig bdy
    ReceivedMsg{..} -> SignedRPC _pDig _pOrig
  fromWire !ts !ks s@(SignedRPC !dig !bdy) = case verifySignedRPC ks s of
    Left !err -> Left $! err
    Right () -> if _digType dig /= RV
      then error $ "Invariant Failure: attempting to decode " ++ show (_digType dig) ++ " with RVWire instance"
      else case S.decode bdy of
        Left !err -> Left $! "Failure to decode RVWire: " ++ err
        Right (RVWire !(t,cid,lli,llt)) -> Right $! RequestVote t cid lli llt $ ReceivedMsg dig bdy ts
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}
