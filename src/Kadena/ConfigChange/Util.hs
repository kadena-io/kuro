{-# LANGUAGE AllowAmbiguousTypes #-}

module Kadena.ConfigChange.Util
  ( getMissingKeys
  ) where

import qualified Crypto.Ed25519.Pure as Ed25519
import qualified Data.Map as Map

import Kadena.Config.TMVar
import qualified Kadena.Crypto as KC
import Kadena.Types.Base
import Kadena.Types.Command (CCPayload(..))

import qualified Pact.Types.Command as P (Payload(..))
import Pact.Types.Command
import Pact.Types.Util (toB16Text)

getMissingKeys :: Config -> CCPayload -> IO [Alias]
getMissingKeys cfg payload = do
  let signerKeys = KC._siPubKey <$> _ccpSigners payload
  let filtered = filter f (Map.toList (_adminKeys cfg)) where
        f (_, k) = notElem k signerKeys
  return $ fmap fst filtered
