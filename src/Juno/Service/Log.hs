
module Juno.Service.Log where

import Control.Lens hiding (Index, (|>))
import Control.Concurrent (putMVar)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict

import Juno.Types.Comms
import Juno.Types.Service.Log

initLogThread :: LogServiceChannel -> (String -> IO()) -> IO ()
initLogThread lsc dbg = do
  env <- return $ LogEnv lsc dbg
  void $ runRWST handle env initLogState

debug :: String -> LogThread ()
debug s = do
  dbg <- view debugPrint
  liftIO $ dbg $ "[LogThread] " ++ s

handle :: LogThread ()
handle = do
  oChan <- view logQueryChannel
  debug "Begin"
  forever $ do
    q <- liftIO $ readComm oChan
    runQuery q

runQuery :: QueryApi -> LogThread ()
runQuery (Query aq mv) = do
  a' <- get
  qr <- return ((`evalQuery` a') <$> aq)
  liftIO $ putMVar mv qr
runQuery (Update ul) = modify (\a' -> updateLogs ul a')
runQuery (Tick t) = do
  t' <- liftIO $ pprintTock t "runQuery"
  debug t'
