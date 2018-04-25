{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Execution.ConfigChange
( processConfigUpdate  
) where

import Data.Aeson
import Data.ByteString (ByteString)   
import qualified Data.Map as Map 

import Kadena.Types.Config

import Pact.Types.Crypto
import Pact.Types.Hash

processConfigUpdate :: ConfigUpdate ByteString -> ProcessedConfigUpdate
processConfigUpdate ConfigUpdate{..} =
  let
    hash' = hash _cuCmd
    sigs = (\(k,s) -> (valid hash' k s,k,s)) <$> Map.toList _cuSigs
    sigsValid :: Bool
    sigsValid = all (\(v,_,_) -> v) sigs
    invalidSigs = filter (\(v,_,_) -> not v) sigs
  in if hash' /= _cuHash
     then ProcessedConfigFailure $! "Hash Mismatch in ConfigUpdate: ours=" ++ show hash' ++ " theirs=" ++ show _cuHash
     else if sigsValid
          then case eitherDecodeStrict' _cuCmd of
                 Left !err -> ProcessedConfigFailure err
                 Right !v -> ProcessedConfigSuccess v (Map.keysSet _cuSigs)
          else ProcessedConfigFailure $! "Sig(s) Invalid: " ++ show invalidSigs
{-# INLINE processConfigUpdate #-}