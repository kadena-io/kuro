{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Types.Api where

import Control.Concurrent.Chan.Unagi
import Control.Monad.Reader
import Data.Aeson hiding (defaultOptions)
import qualified Data.ByteString.Char8 as BS
import Control.Lens
import Data.Monoid
import Prelude hiding (log)

import Snap.Http.Server as Snap
import Snap.Core
import Snap.CORS

import Kadena.Types.Command
import Kadena.Types.Base
import Kadena.Types.Comms
import Kadena.Types.Message
import Kadena.Types.Event
import Kadena.Types.Service.Sender
import Kadena.Types.Config as Config

data ApiEnv = ApiEnv {
      _aiToCommands :: InChan (RequestId, [CommandEntry])
    , _aiCmdStatusMap :: CommandMVarMap
    , _aiLog :: String -> IO ()
    , _aiEvents :: SenderServiceChannel
    , _aiConfig :: Config.Config
}
makeLenses ''ApiEnv
