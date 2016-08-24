{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Types.Message.CMD
  ( Command(..), cmdEntry, cmdClientId, cmdRequestId, cmdProvenance, cmdCryptoVerified
  , CryptoVerified(..)
  , verifyCmd
  , CommandBatch(..), cmdbBatch, cmdbProvenance
  , gatherValidCmdbs
  ) where

import Control.Parallel.Strategies
import Control.Lens
import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import Data.Thyme.Time.Core ()
import GHC.Generics

import Juno.Types.Base
import Juno.Types.Command
import Juno.Types.Config
import Juno.Types.Message.Signed

data CryptoVerified =
  UnVerified |
  Valid |
  Invalid {_cvInvalid :: !String}
  deriving (Show, Eq, Ord, Generic)
instance Serialize CryptoVerified

data Command = Command
  { _cmdEntry      :: !CommandEntry
  , _cmdClientId   :: !NodeId
  , _cmdRequestId  :: !RequestId
  , _cmdCryptoVerified :: !CryptoVerified
  , _cmdProvenance :: !Provenance
  }
  deriving (Show, Eq, Ord, Generic)
makeLenses ''Command

data CMDWire = CMDWire !(CommandEntry, NodeId, RequestId)
  deriving (Show, Generic)
instance Serialize CMDWire

instance WireFormat Command where
  toWire nid pubKey privKey Command{..} = case _cmdProvenance of
    NewMsg -> let bdy = S.encode $ CMDWire (_cmdEntry, _cmdClientId, _cmdRequestId)
                  sig = sign bdy privKey pubKey
                  dig = Digest nid sig pubKey CMD
              in SignedRPC dig bdy
    ReceivedMsg{..} -> SignedRPC _pDig _pOrig
  fromWire !ts !_ks _s@(SignedRPC !dig !bdy) =
        if _digType dig /= CMD
        then error $ "Invariant Failure: attempting to decode " ++ show (_digType dig) ++ " with CMDWire instance"
        else case S.decode bdy of
            Left !err -> Left $! "Failure to decode CMDWire: " ++ err
            Right (CMDWire !(ce,nid,rid)) -> Right $! Command ce nid rid UnVerified $ ReceivedMsg dig bdy ts
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}

verifyCmd :: KeySet -> Command -> CryptoVerified
verifyCmd !ks Command{..} = case _cmdCryptoVerified of
  Valid ->_cmdCryptoVerified
  Invalid _ ->_cmdCryptoVerified
  UnVerified -> case _cmdProvenance of
    NewMsg ->_cmdCryptoVerified
    ReceivedMsg !dig !bdy _ -> case verifySignedRPC ks $! SignedRPC dig bdy of
      Left !err -> Invalid err
      Right () -> Valid

-- TODO: kill provenance for CommandBatch.
data CommandBatch = CommandBatch
  { _cmdbBatch :: ![Command]
  , _cmdbProvenance :: !Provenance
  } deriving (Show, Eq, Generic)
makeLenses ''CommandBatch

instance WireFormat CommandBatch where
  toWire nid pubKey privKey CommandBatch{..} = case _cmdbProvenance of
    NewMsg -> let bdy = S.encode ((toWire nid pubKey privKey <$> _cmdbBatch) `using` parList rseq)
                  sig = sign bdy privKey pubKey
                  dig = Digest nid sig pubKey CMDB
              in SignedRPC dig bdy
    ReceivedMsg{..} -> SignedRPC _pDig _pOrig
  fromWire !ts !ks s@(SignedRPC dig bdy) = case verifySignedRPC ks s of
    Left !err -> Left err
    Right () -> if _digType dig /= CMDB
      then error $! "Invariant Failure: attempting to decode " ++ show (_digType dig) ++ " with CMDBWire instance"
      else case S.decode bdy of
        Left !err -> Left $ "Failure to decode CMDBWire: " ++ err
        Right !cmdb' -> gatherValidCmdbs (ReceivedMsg dig bdy ts) ((fromWire ts ks <$> cmdb') `using` parList rseq)
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}

gatherValidCmdbs :: Provenance -> [Either String Command] -> Either String CommandBatch
gatherValidCmdbs prov ec = (`CommandBatch` prov) <$> sequence ec
{-# INLINE gatherValidCmdbs #-}
