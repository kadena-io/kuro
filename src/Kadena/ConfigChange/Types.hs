{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.ConfigChange.Types
  ( ConfigChange (..)
  , ConfigChangeEvent (..)
  , ConfigChangeChannel (..)
  , ConfigChangeEnv (..), cfgChangeChannel, config, debugPrint, publishMetric
  , ConfigChangeService
  , ConfigChangeState (..)
  ) where

import Control.Concurrent.Chan (Chan)
import Control.Lens (makeLenses)
import Control.Monad.Trans.RWS.Lazy
import Data.Set (Set)
import Kadena.Types.Base
import Kadena.Types.Comms
import Kadena.Types.Config
import Kadena.Types.Event (Beat)
import Kadena.Types.Metric

data ConfigChangeEvent =
  CfgChange ConfigChange |
  Heart Beat
  deriving Eq

data ConfigChange = ConfigChange
  { newNodeSet :: !(Set NodeId)
  , consensusLists :: ![Set NodeId]
  } deriving Eq

newtype ConfigChangeChannel = ConfigChangeChannel (Chan ConfigChangeEvent)

instance Comms ConfigChangeEvent ConfigChangeChannel where
  initComms = ConfigChangeChannel <$> initCommsNormal
  readComm (ConfigChangeChannel c) = readCommNormal c
  writeComm (ConfigChangeChannel c) = writeCommNormal c

data ConfigChangeEnv = ConfigChangeEnv
  { _cfgChangeChannel :: !ConfigChangeChannel
  , _debugPrint :: !(String -> IO ())
  , _publishMetric :: !(Metric -> IO ())
  , _config :: Config
  }
makeLenses ''ConfigChangeEnv

type ConfigChangeService = RWST ConfigChangeEnv () ConfigChangeState IO

data ConfigChangeState = ConfigChangeState
  { _cssTbd :: !Int
  } deriving (Show, Eq)
