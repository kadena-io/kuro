{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.ConfigChange.Types
  ( ConfigChange (..)
  , ConfigChangeChannel
  , ConfigChangeService
  , ConfigChangeState(..)
  ) where

import Control.Concurrent.Chan (Chan)    
--import Control.Lens (makeLenses)
import Control.Monad.Trans.RWS.Lazy
import Kadena.Types.Comms
import Kadena.Types.Event (Beat)

data ConfigChange = 
  Bounce | 
  Heart Beat 
  deriving Eq

newtype ConfigChangeChannel = ConfigChangeChannel (Chan ConfigChange)

instance Comms ConfigChange ConfigChangeChannel where
  initComms = ConfigChangeChannel <$> initCommsNormal
  readComm (ConfigChangeChannel c) = readCommNormal c
  writeComm (ConfigChangeChannel c) = writeCommNormal c

data ConfigChangeEnv = ConfigChangeEnv
  { _cceTbd :: !Int
  } deriving (Show, Eq)
-- makeLenses ''ConfigChangeEnv

type ConfigChangeService s = RWST ConfigChangeEnv () s IO

data ConfigChangeState = ConfigChangeState
  { _cssTbd :: !Int
  } deriving (Show, Eq)
-- makeLenses ''ConfigChangeState
