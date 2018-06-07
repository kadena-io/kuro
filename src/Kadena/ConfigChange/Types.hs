{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.ConfigChange.Types
  ( ConfigChange (..)
  , ConfigChangeApiReq (..)
  , ConfigChangeEvent (..)
  , ConfigChangeChannel (..)
  , ConfigChangeEnv (..), cfgChangeChannel, config, debugPrint, publishMetric
  , ConfigChangeService
  , ConfigChangeState (..)
  ) where

import Control.Concurrent.Chan (Chan)
import Control.Lens (makeLenses)
import Control.Monad.Trans.RWS.Lazy
import Data.Aeson
import GHC.Generics (Generic)
import Data.Set (Set)
import Kadena.Types.Base
import Kadena.Types.Command (ClusterChangeInfo)
import Kadena.Types.Comms
import Kadena.Types.Config
import Kadena.Types.Event (Beat)
import Kadena.Types.Metric
import qualified Pact.Types.Command as Pact
import qualified Pact.Types.Util as Pact

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

data ConfigChangeApiReq = ConfigChangeApiReq
  { _ylccInfo :: ClusterChangeInfo
  , _ylccKeyPairs :: ![Pact.UserSig]
  , _ylccNonce :: Maybe String
  } deriving (Eq,Show,Generic)
instance ToJSON ConfigChangeApiReq where toJSON = Pact.lensyToJSON 5
instance FromJSON ConfigChangeApiReq where parseJSON = Pact.lensyParseJSON 5