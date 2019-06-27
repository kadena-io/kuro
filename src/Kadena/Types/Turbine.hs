{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Turbine
  ( ReceiverEnv(..)
  , turbineDispatch
  , turbineKeySet
  , turbineDebugPrint
  , restartTurbo
  ) where

import Control.Concurrent (MVar)
import Control.Lens

import Kadena.Crypto (KeySet(..))
import Kadena.Types.Dispatch (Dispatch(..))

data ReceiverEnv = ReceiverEnv
  { _turbineDispatch :: Dispatch
  , _turbineKeySet :: KeySet
  , _turbineDebugPrint :: String -> IO ()
  , _restartTurbo :: MVar String
  }
makeLenses ''ReceiverEnv
