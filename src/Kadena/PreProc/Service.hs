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
import Control.Parallel.Strategies

import Data.Thyme.Clock
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq

import Kadena.PreProc.Types as X
import Kadena.Types.Dispatch (Dispatch)
import qualified Kadena.Types.Dispatch as D

initPreProcEnv
  :: Dispatch
  -> Int
  -> (String -> IO ())
  -> IO UTCTime
  -> Bool
  -> ProcessRequestEnv
initPreProcEnv dispatch' threadCount' debugPrint' getTimestamp' usePar' = ProcessRequestEnv
  { _processRequestChannel = dispatch' ^. D.processRequestChannel
  , _threadCount = threadCount'
  , _debugPrint = debugPrint'
  , _getTimestamp = getTimestamp'
  , _usePar = usePar'
  }

runPreProcService :: ProcessRequestEnv -> IO ()
runPreProcService env = do
  let dbg = env ^. debugPrint
  dbg "[Service|PreProc] Launch!"
  if env ^. usePar
  then do
    viaPar env
  else do
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

ppBeat :: Beat -> ProcessRequestService ()
ppBeat b = liftIO (pprintBeat b) >>= debug

handle :: ProcessRequestChannel -> ProcessRequestService ()
handle workChan = do
  liftIO (readComm workChan) >>= \case
    (CommandPreProc rpp) -> do
      hitPreProc <- now
      liftIO $! void $! runPreproc hitPreProc rpp
    Heart t -> ppBeat t
{-# INLINE handle #-}

handleCmdPar :: UTCTime -> Seq ProcessRequest -> ProcessRequestService ()
handleCmdPar startTime s = do
  res <- return $! (evalPreProcCmd <$> s `using` parTraversable rseq)
  endTime <- now
  mapM_ (liftIO . finishPreProc startTime endTime) res
{-# INLINE handleCmdPar #-}

evalPreProcCmd :: ProcessRequest -> FinishedPreProc
evalPreProcCmd (CommandPreProc rpp) = runPreprocPure rpp
evalPreProcCmd Heart{} = error $ "Invariant Error: `evalPreProcCmd` caught a HeartBeat"
{-# INLINE evalPreProcCmd #-}

filterBatch :: Seq ProcessRequest -> (Seq ProcessRequest, Seq ProcessRequest)
filterBatch s = Seq.partition isHB s
  where
    isHB :: ProcessRequest -> Bool
    isHB (Heart _) = True
    isHB (CommandPreProc _) = False
{-# INLINE filterBatch #-}

viaPar :: ProcessRequestEnv -> IO ()
viaPar env@ProcessRequestEnv{..} = do
  let getWork = filterBatch <$> readComms _processRequestChannel _threadCount
  (flip runReaderT) env $ forever $ do
    (hbs, newWork) <- liftIO $ getWork
    unless (Seq.null hbs) $ forM_ hbs $ \case
      Heart t -> ppBeat t
      CommandPreProc{} -> error $ "Invariant Error: `viaPar` caught a CommandPreProc"
    unless (Seq.null newWork) $ do
      startTime <- now
      handleCmdPar startTime newWork
{-# INLINE viaPar #-}
