{-# LANGUAGE AllowAmbiguousTypes #-}

module Kadena.ConfigChange.Util
  ( getMissingKeys
  ) where

import qualified Data.Map as Map

import Kadena.Config.TMVar
import qualified Kadena.Types.Crypto as KC
import Kadena.Types.Base
import Kadena.Types.Command (CCPayload(..))

getMissingKeys :: Config -> CCPayload -> IO [Alias]
getMissingKeys cfg payload = do
  let signerKeys = KC._siPubKey <$> _ccpSigners payload
  let filtered = filter f (Map.toList (_adminKeys cfg)) where
        f (_, k) = notElem k signerKeys
  return $ fmap fst filtered
