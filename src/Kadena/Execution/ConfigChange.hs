{-# LANGUAGE OverloadedStrings #-}

module Kadena.Execution.ConfigChange
( processClusterChange
) where

import Control.Exception
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base16 as B16
import qualified Data.Aeson as A
import Data.String.Conv (toS)
import qualified Crypto.Ed25519.Pure as Ed25519 (PublicKey, Signature(..))

import qualified Pact.Types.Command as P (UserSig(..))
import qualified Pact.Types.Hash as P (hash)
import Pact.Types.Hash (PactHash, toUntypedHash)

import Kadena.Types.Crypto (Signer(..), valid)
import Kadena.Types.Message.Signed (DeserializationError(..))
import Kadena.Types.Command(CCPayload(..), ClusterChangeCommand(..), ProcessedClusterChg (..))

processClusterChange :: ClusterChangeCommand ByteString -> ProcessedClusterChg CCPayload
processClusterChange cmd =
  let
    hash' = P.hash $ _cccPayload cmd
    payload = _cccPayload $ decodeCCPayload cmd
    sigZips = zip (_ccpSigners payload) (_cccSigs cmd)
    boolSigs = fmap (validateSig hash') sigZips
    sigsValid = all (\(v,_,_) -> v) boolSigs :: Bool
    invalidSigs = filter (\(v,_,_) -> not v) boolSigs
  in if hash' /= (_cccHash cmd)
     then ProcClusterChgFail $! "Kadena.Execution.ConfigChange - Hash Mismatch in cluster change: "
                             ++ "ours=" ++ show hash' ++ "( a hash of: " ++ show (_cccPayload cmd) ++ ")"
                             ++ " theirs=" ++ show (_cccHash cmd)
     else if sigsValid
      then ProcClusterChgSucc (decodeCCPayload cmd)
      else ProcClusterChgFail $! "Sig(s) Invalid: " ++ show invalidSigs
{-# INLINE processClusterChange #-}

decodeCCPayload :: ClusterChangeCommand ByteString -> ClusterChangeCommand CCPayload
decodeCCPayload bsCmd =
  let decoded = A.eitherDecodeStrict' (_cccPayload bsCmd) :: Either String CCPayload
  in case decoded of
    Left err -> throw $ DeserializationError $ err ++ "\n### for ###\n" ++ show (_cccPayload bsCmd)
    Right ccpl -> ClusterChangeCommand
                    { _cccPayload = ccpl
                    , _cccSigs = _cccSigs bsCmd
                    , _cccHash = _cccHash bsCmd }

validateSig :: PactHash -> (Signer, P.UserSig) ->  (Bool, Ed25519.PublicKey, Ed25519.Signature)
validateSig h (signer, userSig) =
  let pubKey = _siPubKey signer
      sigBytes = toS $ P._usSig  userSig
      sig = Ed25519.Sig $ fst $ B16.decode sigBytes
      b = valid (toUntypedHash h) pubKey sig
  in (b, pubKey, sig)
