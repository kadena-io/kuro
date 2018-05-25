{-# LANGUAGE RecordWildCards #-}

module Kadena.Execution.ConfigChange
( processClusterChange
) where

import qualified Crypto.Ed25519.Pure as Ed (PublicKey, Signature(..), importPublic)
import qualified Data.Serialize as S
import Data.String.Conv

import Pact.Types.Command(UserSig(..))
import Pact.Types.Util(Hash(..))
import Kadena.Types.Config
import Pact.Types.Crypto (valid)
import Pact.Types.Hash (hash)

processClusterChange :: ClusterChangeCommand -> ProcessedClusterChg
processClusterChange cmd@ClusterChangeCommand{..} =
  let
    hash' = hash $ S.encode _cccPayload
    boolSigs = fmap (validateSigs hash') _cccSigs
    sigsValid = all (\(v,_,_) -> v) boolSigs :: Bool
    invalidSigs = filter (\(v,_,_) -> not v) boolSigs
  in if hash' /= _cccHash
     then ProcClusterChgFail $! "Hash Mismatch in cluster change: ours=" ++ show hash' ++ " theirs=" ++ show _cccHash
     else if sigsValid
      then ProcClusterChgSucc cmd
      else ProcClusterChgFail $! "Sig(s) Invalid: " ++ show invalidSigs
{-# INLINE processClusterChange #-}

validateSigs :: Hash -> UserSig -> (Bool, Maybe Ed.PublicKey, Ed.Signature)
validateSigs h UserSig{..} =
  let keyMay = Ed.importPublic $ toS _usPubKey
      sig = Ed.Sig $ toS _usSig
      b = maybe False (\k -> valid h k sig) keyMay
  in (b, keyMay, sig)

