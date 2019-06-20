{-# LANGUAGE AllowAmbiguousTypes #-}

module Kadena.ConfigChange.Util
  ( getMissingKeys
  ) where

import qualified Crypto.Ed25519.Pure as Ed25519
import qualified Data.Map as Map

import Kadena.Config.TMVar
import Kadena.Types.Base

import Pact.Bench (eitherDie)
import qualified Pact.Types.Command as P (Payload(..))
import Pact.Types.Command
import qualified Pact.Types.Crypto as P (Scheme, PublicKey, PrivateKey, Signature)
import qualified Pact.Types.Scheme as P (PPKScheme(..), SPPKScheme)
import Pact.Types.Util (toB16Text)

getMissingKeys :: Config -> Payload m c -> IO [Alias]
getMissingKeys cfg payload = do
  let  signerKeys = _siPubKey <$> _pSigners payload
  let filtered = filter f (Map.toList (_adminKeys cfg)) where
        f (_, k) = notElem (toTxt k) signerKeys
        toTxt = toB16Text . Ed25519.exportPublic
  return $ fmap fst filtered
