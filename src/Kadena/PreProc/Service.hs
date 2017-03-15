{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Kadena.PreProc.Service
  ( initPreProcEnv
  , runPreProcService
  , module X
  ) where

import Control.Lens hiding (Index, (|>))
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Reader
import Control.Concurrent.Async

import Data.Thyme.Clock

import Kadena.PreProc.Types as X
import Kadena.Types.Dispatch (Dispatch)
import qualified Kadena.Types.Dispatch as D

initPreProcEnv
  :: Dispatch
  -> Int
  -> (String -> IO ())
  -> IO UTCTime
  -> ProcessRequestEnv
initPreProcEnv dispatch' threadCount' debugPrint' getTimestamp' = ProcessRequestEnv
  { _processRequestChannel = dispatch' ^. D.processRequestChannel
  , _threadCount = threadCount'
  , _debugPrint = debugPrint'
  , _getTimestamp = getTimestamp'
  }

runPreProcService :: ProcessRequestEnv -> IO ()
runPreProcService env = do
  let dbg = env ^. debugPrint
  dbg "[Service|PreProc] Launch!"
  threads' <- threadPool env
  mapM_ link threads'
  waitAnyCatchCancel threads' >>= \case
    (_,shouldBeUnreachable) -> error $ "unreachable exception reached in preproc... " ++ show shouldBeUnreachable

debug :: String -> ProcessRequestService ()
debug s = do
  dbg <- view debugPrint
  liftIO $! dbg $ "[Service|PreProc] " ++ s

now :: ProcessRequestService UTCTime
now = view getTimestamp >>= liftIO

threadPool :: ProcessRequestEnv -> IO [Async ()]
threadPool env@ProcessRequestEnv{..} = replicateM _threadCount $
  async $ forever $ runReaderT (handle _processRequestChannel) env

handle :: ProcessRequestChannel -> ProcessRequestService ()
handle workChan = do
  liftIO (readComm workChan) >>= \case
    (CommandPreProc rpp) -> do
      hitPreProc <- now
      liftIO $! void $! runPreproc hitPreProc rpp
    Heart t -> do
        liftIO (pprintBeat t) >>= debug
