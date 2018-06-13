{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Execution.ConfigChange
( processClusterChange
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Base16 as B16
import qualified Data.Aeson as A
import Data.String.Conv
import qualified Crypto.Ed25519.Pure as Ed (PublicKey, Signature(..), importPublic)

import Pact.Types.Command(UserSig(..))
import Pact.Types.Util(Hash(..))
import Kadena.Types.Command(CCPayload(..), ClusterChangeCommand(..), ProcessedClusterChg (..))
import Pact.Types.Crypto (valid)
import Pact.Types.Hash (hash)

processClusterChange :: ClusterChangeCommand ByteString -> ProcessedClusterChg CCPayload
processClusterChange cmd =
  let
    hash' = hash $ _cccPayload cmd
    boolSigs = fmap (validateSig hash') (_cccSigs cmd)
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
    Left e -> error $ "JSON payload decode failed: " ++ show e
    Right ccpl -> ClusterChangeCommand
                    { _cccPayload = ccpl
                    , _cccSigs = _cccSigs bsCmd
                    , _cccHash = _cccHash bsCmd }

validateSig :: Hash -> UserSig -> (Bool, Maybe Ed.PublicKey, Ed.Signature)
validateSig h UserSig{..} =
  let keyBytes = toS _usPubKey :: ByteString
      keyMay = Ed.importPublic $ fst $ B16.decode keyBytes
      sigBytes = toS _usSig :: ByteString
      sig = Ed.Sig $ fst $ B16.decode sigBytes
      b = maybe False (\k -> valid h k sig) keyMay
  in (b, keyMay, sig)
