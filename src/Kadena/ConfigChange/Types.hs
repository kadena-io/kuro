{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.ConfigChange.Types
  ( ConfigChange (..)
  ) where

import Data.Set (Set)
import Kadena.Types.Base

data ConfigChange = ConfigChange
  { newNodeSet :: !(Set NodeId)
  , consensusLists :: ![Set NodeId]
  } deriving Eq

