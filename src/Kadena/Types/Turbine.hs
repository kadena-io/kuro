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

import Kadena.Types.Dispatch (Dispatch(..))
import Kadena.Types.KeySet (KeySet(..))

data ReceiverEnv = ReceiverEnv
  { _turbineDispatch :: Dispatch
  , _turbineKeySet :: KeySet
  , _turbineDebugPrint :: String -> IO ()
  , _restartTurbo :: MVar String
  }
makeLenses ''ReceiverEnv

