module Kadena.Types.ConfigChange
  ( ConfigChange (..)
  ) where

import Data.Set (Set)
import Kadena.Types.Base

data ConfigChange = ConfigChange
  { newNodeSet :: !(Set NodeId)
  , consensusLists :: ![Set NodeId]
  } deriving Eq

