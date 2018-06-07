{-# LANGUAGE RecordWildCards #-}

module Kadena.Execution.ConfigChange
( processClusterChange
) where

import Control.Exception
import Data.ByteString (ByteString)
import qualified Data.Serialize as S
import Data.String.Conv
import qualified Crypto.Ed25519.Pure as Ed (PublicKey, Signature(..), importPublic)

import Pact.Types.Command(UserSig(..))
import Pact.Types.Util(Hash(..))
import Kadena.Types.Command(CCPayload(..), ClusterChangeCommand(..), ProcessedClusterChg (..))
import Pact.Types.Crypto (valid)
import Pact.Types.Hash (hash)
import Kadena.Types.Message.Signed (DeserializationError(..))

processClusterChange :: ClusterChangeCommand ByteString -> ProcessedClusterChg CCPayload
processClusterChange cmd@ClusterChangeCommand{..} =
  let
    hash' = hash $ S.encode _cccPayload
    boolSigs = fmap (validateSigs hash') _cccSigs
    sigsValid = all (\(v,_,_) -> v) boolSigs :: Bool
    invalidSigs = filter (\(v,_,_) -> not v) boolSigs
  in if hash' /= _cccHash
     then ProcClusterChgFail $! "Hash Mismatch in cluster change: ours=" ++ show hash' ++ " theirs=" ++ show _cccHash
     else if sigsValid
      then ProcClusterChgSucc (decodeCCPayload cmd)
      else ProcClusterChgFail $! "Sig(s) Invalid: " ++ show invalidSigs
{-# INLINE processClusterChange #-}

decodeCCPayload :: ClusterChangeCommand ByteString -> ClusterChangeCommand CCPayload
decodeCCPayload bsCmd =
  let decoded = S.decode (_cccPayload bsCmd) :: Either String CCPayload
  in case decoded of
    Left err -> throw $ DeserializationError $ err ++ "\n### for ###\n" ++ show (_cccPayload bsCmd)
    Right ccpl -> ClusterChangeCommand
                    { _cccPayload = ccpl
                    , _cccSigs = _cccSigs bsCmd
                    , _cccHash = _cccHash bsCmd }

validateSigs :: Hash -> UserSig -> (Bool, Maybe Ed.PublicKey, Ed.Signature)
validateSigs h UserSig{..} =
  let keyMay = Ed.importPublic $ toS _usPubKey
      sig = Ed.Sig $ toS _usSig
      b = maybe False (\k -> valid h k sig) keyMay
  in (b, keyMay, sig)

