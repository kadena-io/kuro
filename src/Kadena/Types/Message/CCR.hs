{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Message.CCR
  ( ClusterChangeResponse(..), ccrTerm, ccrNodeId, ccrSuccess, ccrConvinced, ccrIndex, ccrHash, ccrProvenance
  , toSetCCR
  , decodeCCRWire
  ) where

import Control.Lens
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import Data.Thyme.Time.Core ()
import GHC.Generics

import Kadena.Types.Base
import Kadena.Types.KeySet
import Kadena.Types.Message.Signed

data ClusterChangeResponse = ClusterChangeResponse
  { _ccrTerm        :: !Term
  , _ccrNodeId      :: !NodeId
  , _ccrSuccess    :: !Bool
  , _ccrConvinced  :: !Bool
  , _ccrIndex      :: !LogIndex
  , _ccrHash       :: !Hash
  , _ccrProvenance  :: !Provenance
  }
  deriving (Show, Eq, Generic)
makeLenses ''ClusterChangeResponse

instance Ord ClusterChangeResponse where
  -- See comments on AppendEntriesResponse...
  (ClusterChangeResponse t n s c i h p) <= (ClusterChangeResponse t' n' s' c' i' h' p') =
    (n,t,i,h,s,c,p) <= (n',t',i',h',s',c',p')

data CCRWire = CCRWire (Term,NodeId,Bool,Bool,LogIndex,Hash)
  deriving (Show, Generic)
instance Serialize CCRWire

instance WireFormat ClusterChangeResponse where
  toWire nid pubKey privKey ClusterChangeResponse{..} = case _ccrProvenance of
    NewMsg -> let bdy = S.encode $ CCRWire ( _ccrTerm
                                           , _ccrNodeId
                                           , _ccrSuccess
                                           , _ccrConvinced
                                           , _ccrIndex
                                           , _ccrHash)
                  hsh = hash bdy
                  sig = sign hsh privKey pubKey
                  dig = Digest (_alias nid) sig pubKey CCR hsh
              in SignedRPC dig bdy
    ReceivedMsg{..} -> SignedRPC _pDig _pOrig
  fromWire !ts !ks s@(SignedRPC !dig !bdy) = case verifySignedRPC ks s of
    Left !err -> Left $! err
    Right () -> if _digType dig /= CCR
      then error $ "Invariant Failure: attempting to decode " ++ show (_digType dig) ++ " with CCRWire instance"
      else case S.decode bdy of
        Left !err -> Left $! "Failure to decode CCRWire: " ++ err
        Right (CCRWire !(t,nid,s',c,i,h)) -> Right $! ClusterChangeResponse t nid s' c i h $ ReceivedMsg dig bdy ts
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}

toSetCCR :: [Either String ClusterChangeResponse] -> Either String (Set ClusterChangeResponse)
toSetCCR eCcrs = go eCcrs Set.empty
  where
    go [] s = Right $! s
    go (Right ccr:ccrs) s = go ccrs (Set.insert ccr s)
    go (Left err:_) _ = Left $! err
{-# INLINE toSetCCR #-}

decodeCCRWire :: Maybe ReceivedAt -> KeySet -> [SignedRPC] -> Either String (Set ClusterChangeResponse)
decodeCCRWire ts ks votes' = go votes' Set.empty
  where
    go [] s = Right $! s
    go (v:vs) s = case fromWire ts ks v of
      Left err -> Left $! err
      Right ccr' -> go vs (Set.insert ccr' s)
{-# INLINE decodeCCRWire #-}
