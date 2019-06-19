{-# LANGUAGE AllowAmbiguousTypes #-}

module Kadena.ConfigChange.Util
  ( getMissingKeys
  ) where

import qualified Data.Map as Map

import Kadena.Config.TMVar
import Kadena.Types.Base

import Pact.Bench (eitherDie)
import qualified Pact.Types.Command as P (UserSig)
import Pact.Types.Command
import qualified Pact.Types.Crypto as P (Scheme, PublicKey, PrivateKey, Signature)
import qualified Pact.Types.Scheme as P (PPKScheme(..), SPPKScheme)
import Pact.Types.Util (fromText')

-- TODO: [UserSig] needs to become Payload...
getMissingKeys :: P.Scheme s => s -> Config -> [UserSig] -> IO [Alias]
getMissingKeys scheme cfg sigs = do
  let textKeys = fmap _usPubKey sigs
  pubKeys <- traverse (eitherDie . fromText') textKeys :: IO [P.PublicKey s]
  let filtered = filter f (Map.toList (_adminKeys cfg)) where
        f (_, k) = notElem k pubKeys
  return $ fmap fst filtered
