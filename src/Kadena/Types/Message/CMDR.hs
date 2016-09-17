{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Message.CMDR
  ( CommandResponse(..), cmdrResult, cmdrNodeId, cmdrRequestId, cmdrLatency, cmdrProvenance
  ) where

import Control.Lens
import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import qualified Data.ByteString as BS
import Data.Thyme.Time.Core ()
import GHC.Generics
import GHC.Int (Int64)

import Kadena.Types.Base
import Kadena.Types.Command
import Kadena.Types.Message.Signed

data CommandResponse = CommandResponse
  { _cmdrResult     :: !CommandResult
  , _cmdrNodeId     :: !NodeId
  , _cmdrRequestId  :: !RequestId
  , _cmdrLatency    :: !Int64
  , _cmdrProvenance :: !Provenance
  }
  deriving (Show, Eq, Generic)
makeLenses ''CommandResponse

data CMDRWire = CMDRWire (CommandResult, NodeId, RequestId, Int64)
  deriving (Show, Generic)
instance Serialize CMDRWire


-- NB: eventually we need to service async and when that happens we'll need to start signing again
-- NB| but until then the signing hurts performance as it's sync
-- TODO: scrap terrible API, re-integrate signing of CMDR's
instance WireFormat CommandResponse where
  toWire nid pubKey _privKey CommandResponse{..} = case _cmdrProvenance of
    NewMsg -> let bdy = S.encode $ CMDRWire (_cmdrResult,_cmdrNodeId,_cmdrRequestId,_cmdrLatency)
                  sig = Sig BS.empty
                  dig = Digest nid sig pubKey CMDR
              in SignedRPC dig bdy
    ReceivedMsg{..} -> SignedRPC _pDig _pOrig
--  fromWire ts !ks s@(SignedRPC !dig !bdy) = case verifySignedRPC ks s of
--    Left !err -> Left err
--    Right () -> if _digType dig /= CMDR
  fromWire ts !_ks _s@(SignedRPC !dig !bdy) = if _digType dig /= CMDR
      then error $ "Invariant Failure: attempting to decode " ++ show (_digType dig) ++ " with CMDRWire instance"
      else case S.decode bdy of
        Left !err -> Left $! "Failure to decode CMDRWire: " ++ err
        Right (CMDRWire !(r,nid,rid,lat)) -> Right $! CommandResponse r nid rid lat $ ReceivedMsg dig bdy ts
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}
