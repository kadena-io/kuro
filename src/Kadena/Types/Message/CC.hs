{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Message.CC
  ( ClusterChangeMsg(..), ccAppendEntries, ccState
  ) where

import Codec.Compression.LZ4
import Control.Lens
import Control.Parallel.Strategies
import Data.Maybe
import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import qualified Data.Set as Set
import Data.Thyme.Time.Core ()
import GHC.Generics

import Kadena.Log
import Kadena.Types.Base
import Kadena.Types.Command (CCState)
import Kadena.Types.Log
import Kadena.Types.Message.AE (AppendEntries(..))
import Kadena.Types.Message.RVR
import Kadena.Types.Message.Signed

data ClusterChangeMsg = ClusterChangeMsg
  { _ccState :: !CCState
  , _ccAppendEntries :: AppendEntries
  } deriving (Show, Eq, Generic)
makeLenses ''ClusterChangeMsg

data CCWire = CCWire (CCState,Term,NodeId,LogIndex,Term,[LEWire],[SignedRPC])
  deriving (Show, Generic)
instance Serialize CCWire

instance WireFormat ClusterChangeMsg where
  toWire nid pubKey privKey (ClusterChangeMsg cchgState AppendEntries{..}) =
    case _aeProvenance of
      NewMsg ->
        let bdy = fromMaybe (error "failure to compress CC") $ compressHC $ S.encode $
                    CCWire (cchgState, _aeTerm , _leaderId, _prevLogIndex, _prevLogTerm, encodeLEWire _aeEntries
                    , toWire nid pubKey privKey <$> Set.toList _aeQuorumVotes)
            hsh = hash bdy
            sig = sign hsh privKey pubKey
            dig = Digest (_alias nid) sig pubKey CC hsh
        in SignedRPC dig bdy
      ReceivedMsg{..} -> SignedRPC _pDig _pOrig

  fromWire !ts !ks s@(SignedRPC !dig !bdy) =
    case verifySignedRPC ks s of
      Left !err -> Left $! err
      Right () ->
        if _digType dig /= CC
          then error $ "Invariant Failure: attempting to decode " ++ show (_digType dig)
                    ++ " with CCWire instance"
          else case maybe (Left "Decompression failure") S.decode $ decompress bdy of
            Left err -> Left $! "Failure to decode CCWire: " ++ err
            Right (CCWire (st,t,lid,pli,pt,les,vts)) -> runEval $ do
                eLes <- rpar (toLogEntries ((decodeLEWire' ts <$> les) `using` parList rseq))

                -- MLN: TODO is calling toSetRvr related to having multiple consensus lists
                -- for config change?
                eRvr <- rseq (toSetRvr ((fromWire ts ks <$> vts) `using` parList rseq))
                case eRvr of
                  Left !err -> return $! Left $! "Caught an invalid RVR in a CC: " ++ err
                  Right !vts' -> do
                    _ <- rseq eLes
                    return $! Right $! ClusterChangeMsg st (AppendEntries t lid pli pt eLes vts' (ReceivedMsg dig bdy ts))
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}
