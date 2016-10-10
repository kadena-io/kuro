{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Message.CMD
  ( Command(..), cmdEntry, cmdClientId, cmdRequestId, cmdProvenance, cmdCryptoVerified
  , Commands(..)
  , CMDWire(..)
  , mkCmdRpc, mkCmdBatchRPC
  , getCmdSigOrInvariantError
  , getCmdHashOrInvariantError
  , toRequestKey
  , hashCmdForBloom
  , hashReqKeyForBloom
  , CryptoVerified(..)
  , verifyCmd
  , CommandBatch(..), cmdbBatch, cmdbProvenance
  , gatherValidCmdbs
  ) where

import Control.Parallel.Strategies
import Control.Lens

import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Binary

import Data.Thyme.Time.Core ()
import GHC.Generics

import Kadena.Types.Base
import Kadena.Types.Command
import Kadena.Types.Config
import Kadena.Types.Message.Signed

data CryptoVerified =
  UnVerified |
  Valid |
  Invalid {_cvInvalid :: !String}
  deriving (Show, Eq, Ord, Generic)
instance Serialize CryptoVerified

data Command = Command
  { _cmdEntry      :: !CommandEntry
  , _cmdClientId   :: !Alias
  , _cmdRequestId  :: !RequestId
  , _cmdCryptoVerified :: !CryptoVerified
  , _cmdProvenance :: !Provenance
  }
  deriving (Show, Eq, Ord, Generic)
makeLenses ''Command

data CMDWire = CMDWire !(CommandEntry, Alias, RequestId)
  deriving (Show, Generic)
instance Serialize CMDWire

-- TODO: MASSIVE TODO/ISSUE -- CMD and PactMessage need to be unified, I've altered fromWire and to wire for now to make this work
-- The issue is that the alias and rid are in the CommandEntry now, so we don't sign/verify against CMDWire but just CommandEntry
-- and use CMDWire to duplicate Alias and rid
mkCmdRpc :: CommandEntry -> Alias -> RequestId -> Digest -> SignedRPC
mkCmdRpc ce a ri d = SignedRPC d (S.encode $ CMDWire (ce, a, ri))

instance WireFormat Command where
  toWire nid pubKey privKey Command{..} = case _cmdProvenance of
    NewMsg -> let bdy = S.encode $ CMDWire (_cmdEntry, _cmdClientId, _cmdRequestId)
                  hsh = hash $ unCommandEntry _cmdEntry
                  sig = sign hsh privKey pubKey
                  dig = Digest (_alias nid) sig pubKey CMD hsh
              in SignedRPC dig bdy
    ReceivedMsg{..} -> SignedRPC _pDig _pOrig
  fromWire !ts !_ks s@(SignedRPC !dig !bdy) =
        if _digType dig /= CMD
        then error $ "Invariant Failure: attempting to decode " ++ show (_digType dig) ++ " with CMDWire instance"
        else case S.decode bdy of
          Left !err -> Left $! "Failure to decode CMDWire: " ++ err
          Right (CMDWire !(ce,nid,rid)) -> let ourHash = hash $ unCommandEntry ce
            in if ourHash /= _digHash dig
               then Left $! "Unable to verify SignedRPC hash: "
                        ++ " our=" ++ show ourHash
                        ++ " theirs=" ++ show (_digHash dig)
                        ++ " in " ++ show s
               else Right $! Command ce nid rid UnVerified $ ReceivedMsg dig bdy ts
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}

verifyCmd :: KeySet -> Command -> CryptoVerified
verifyCmd !ks Command{..} = case _cmdCryptoVerified of
  Valid -> _cmdCryptoVerified
  Invalid _ -> _cmdCryptoVerified
  UnVerified -> case _cmdProvenance of
    NewMsg -> _cmdCryptoVerified
    ReceivedMsg !dig !bdy _ -> case verifySignedRPCNoReHash ks $! SignedRPC dig bdy of
      Left !err -> Invalid err
      Right () -> Valid

getCmdHashOrInvariantError :: String -> Command -> Hash
getCmdHashOrInvariantError where' s@Command{..} = case _cmdProvenance of
  NewMsg -> error $! where'
    ++ ": This should be unreachable, somehow an AE got through with a LogEntry that contained an unsigned Command" ++ show s
  ReceivedMsg{..} -> _digHash _pDig
{-# INLINE getCmdHashOrInvariantError #-}

getCmdSigOrInvariantError :: String -> Command -> Signature
getCmdSigOrInvariantError where' s@Command{..} = case _cmdProvenance of
  NewMsg -> error $! where'
    ++ ": This should be unreachable, somehow an AE got through with a LogEntry that contained an unsigned Command" ++ show s
  ReceivedMsg{..} -> _digSig _pDig
{-# INLINE getCmdSigOrInvariantError #-}

toRequestKey :: String -> Command -> RequestKey
toRequestKey where' cmd = RequestKey $ getCmdHashOrInvariantError where' cmd
{-# INLINE toRequestKey #-}

hashReqKeyForBloom :: RequestKey -> [Word32]
hashReqKeyForBloom (RequestKey h) = decode . BL.fromStrict <$> go (unHash h)
  where
    go v
      | B.null v = []
      | otherwise = let (a,b) = B.splitAt 4 v in a : go b
{-# INLINE hashReqKeyForBloom #-}

hashCmdForBloom :: String -> Command -> [Word32]
hashCmdForBloom where' cmd = hashReqKeyForBloom $! toRequestKey where' cmd
{-# INLINE hashCmdForBloom #-}

newtype Commands = Commands { unCommands :: [Command] } deriving (Show, Eq)

-- TODO: kill provenance for CommandBatch.
data CommandBatch = CommandBatch
  { _cmdbBatch :: !Commands
  , _cmdbProvenance :: !Provenance
  } deriving (Show, Eq, Generic)
makeLenses ''CommandBatch

mkCmdBatchRPC :: [SignedRPC] -> Digest -> SignedRPC
mkCmdBatchRPC cmds d = SignedRPC d (S.encode cmds)

instance WireFormat CommandBatch where
  toWire nid pubKey privKey CommandBatch{..} = case _cmdbProvenance of
    NewMsg -> let bdy = S.encode ((toWire nid pubKey privKey <$> unCommands _cmdbBatch) `using` parList rseq)
                  hsh = hash bdy
                  sig = sign hsh privKey pubKey
                  dig = Digest (_alias nid) sig pubKey CMDB hsh
              in SignedRPC dig bdy
    ReceivedMsg{..} -> SignedRPC _pDig _pOrig
  fromWire !ts !ks (SignedRPC dig bdy) = -- TODO, no sigs on CMDB for now, but should maybe sign the request ids or something
    if _digType dig /= CMDB
      then error $! "Invariant Failure: attempting to decode " ++ show (_digType dig) ++ " with CMDBWire instance"
      else case S.decode bdy of
        Left !err -> Left $ "Failure to decode CMDBWire: " ++ err
        Right !cmdb' -> gatherValidCmdbs (ReceivedMsg dig bdy ts) ((fromWire ts ks <$> cmdb') `using` parList rseq)
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}

gatherValidCmdbs :: Provenance -> [Either String Command] -> Either String CommandBatch
gatherValidCmdbs prov ec = (\cmds -> CommandBatch (Commands cmds) prov) <$> sequence ec
{-# INLINE gatherValidCmdbs #-}
