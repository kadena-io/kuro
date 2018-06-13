module Kadena.ConfigChange.Util
  ( getMissingKeys
  ) where

import qualified Data.Map as Map
import Data.Maybe
import Kadena.Types.Base
import Kadena.Types.Config
import Kadena.Util.Util
import Pact.Types.Command

getMissingKeys :: Config -> [UserSig]-> [Alias]
getMissingKeys cfg sigs =
    let textKeys = fmap _usPubKey sigs
        pubKeys = catMaybes $ fmap asPublic textKeys
        filtered = filter f (Map.toList (_adminKeys cfg)) where
            f :: (Alias, PublicKey) -> Bool
            f (_, k) = notElem k pubKeys
    in fmap fst filtered