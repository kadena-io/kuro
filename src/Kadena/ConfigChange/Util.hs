module Kadena.ConfigChange.Util
  ( getMissingKeys
  ) where

import qualified Data.Map as Map

import Kadena.Config.TMVar
import Kadena.Types.Base

import Pact.Bench (eitherDie)
import Pact.Types.Command
import Pact.Types.Util (fromText')

getMissingKeys :: Config -> [UserSig]-> IO [Alias]
getMissingKeys cfg sigs = do
  let textKeys = fmap _usPubKey sigs
  pubKeys <- traverse (eitherDie . fromText') textKeys :: IO [PublicKey]
  let filtered = filter f (Map.toList (_adminKeys cfg)) where
        f (_, k) = notElem k pubKeys
  return $ fmap fst filtered