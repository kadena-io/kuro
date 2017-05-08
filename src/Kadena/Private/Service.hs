{-# LANGUAGE RecordWildCards #-}
module Kadena.Private.Service
  (runPrivateService,encrypt,decrypt)
  where

import Control.Concurrent (putMVar,newEmptyMVar,takeMVar)
import Control.Monad (void,forever)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Catch (catch)
import Control.Exception (SomeException)

import Kadena.Types.Dispatch (Dispatch(..))
import Kadena.Types.Config (Config(..))
import Kadena.Types.Base (_alias)
import Kadena.Types.Comms (readComm,writeComm)

import Kadena.Private.Types
import Kadena.Private.Private
import Kadena.Types.Entity

runPrivateService :: Dispatch -> Config -> (String -> IO ()) -> EntityConfig -> IO ()
runPrivateService Dispatch{..} Config{..} logFn EntityConfig{..} = do
  ps <- PrivateState <$> initSessions _ecLocal _ecRemotes
  let pe = PrivateEnv _ecLocal _ecRemotes (_alias _nodeId)
  void $ runPrivate pe ps (handle _privateChannel (\s -> liftIO $ logFn $ "[Service|Private] " ++ s))

handle :: PrivateChannel -> (String -> Private ()) -> Private ()
handle chan logFn = do
  logFn "Launch!"
  forever $ do
    q <- liftIO $ readComm chan
    case q of
      Encrypt pt mv -> catch
        (do
            ct <- sendPrivate pt
            liftIO $ putMVar mv (Right ct))
        (\e -> liftIO $ putMVar mv (Left e))
      Decrypt ct mv -> catch
        (do
            ptm <- handlePrivate ct
            liftIO $ putMVar mv (Right ptm))
        (\e -> liftIO $ putMVar mv (Left e))

encrypt :: PrivateChannel -> PrivatePlaintext -> IO (Either SomeException PrivateCiphertext)
encrypt chan pp = do
  mv <- newEmptyMVar
  writeComm chan (Encrypt pp mv)
  takeMVar mv


decrypt :: PrivateChannel -> PrivateCiphertext -> IO (Either SomeException (Maybe PrivatePlaintext))
decrypt chan pc = do
  mv <- newEmptyMVar
  writeComm chan (Decrypt pc mv)
  takeMVar mv
