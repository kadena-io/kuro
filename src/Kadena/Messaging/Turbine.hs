module Kadena.Messaging.Turbine
  ( runMessageReceiver
  , ReceiverEnv(..), dispatch, keySet, debugPrint, restartTurbo
  ) where

import Control.Concurrent (takeMVar)
import Control.Lens
import Control.Monad
import Control.Monad.Reader

import Kadena.Util.Util (foreverRetry)

import Kadena.Messaging.Turbine.Types
import Kadena.Messaging.Turbine.AER
import Kadena.Messaging.Turbine.CMD
import Kadena.Messaging.Turbine.General
import Kadena.Messaging.Turbine.RV

runMessageReceiver :: ReceiverEnv -> IO ()
runMessageReceiver env = void $ foreverRetry (env ^. debugPrint) "[Turbo|MsgReceiver]" $ runReaderT messageReceiver env

-- | Thread to take incoming messages and write them to the event queue.
messageReceiver :: ReaderT ReceiverEnv IO ()
messageReceiver = do
  env <- ask
  debug <- view debugPrint
  void $ liftIO $ foreverRetry debug turbineRv $ runReaderT rvAndRvrTurbine env
  void $ liftIO $ foreverRetry debug turbineAer $ runReaderT aerTurbine env
  void $ liftIO $ foreverRetry debug turbineCmd $ runReaderT cmdTurbine env
  void $ liftIO $ foreverRetry debug turbineGeneral $ runReaderT generalTurbine env
  liftIO $ takeMVar (_restartTurbo env) >>= debug . (++) "restartTurbo MVar caught saying: "
