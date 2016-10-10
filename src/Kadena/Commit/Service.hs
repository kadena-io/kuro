{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Commit.Service
  ( initCommitEnv
  , runCommitService
  , module X
  ) where

import Control.Lens hiding (Index, (|>))
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict

import qualified Data.Map.Strict as Map
import Data.Thyme.Clock
import Data.Maybe (fromJust)

import Kadena.Commit.Types as X
import Kadena.Types.Dispatch (Dispatch)
import qualified Kadena.Types.Dispatch as D
import qualified Kadena.History.Types as History
import qualified Kadena.Log.Service as Log

initCommitEnv
  :: Dispatch
  -> (String -> IO ())
  -> ApplyFn
  -> (Metric -> IO ())
  -> IO UTCTime
  -> CommitEnv
initCommitEnv dispatch' debugPrint' applyLogEntry'
              publishMetric' getTimestamp' = CommitEnv
  { _commitChannel = dispatch' ^. D.commitService
  , _historyChannel = dispatch' ^. D.historyChannel
  , _applyLogEntry = applyLogEntry'
  , _debugPrint = debugPrint'
  , _publishMetric = publishMetric'
  , _getTimestamp = getTimestamp'
  }

runCommitService :: CommitEnv -> NodeId -> KeySet -> IO ()
runCommitService env nodeId' keySet' = do
  initCommitState <- return $! CommitState { _nodeId = nodeId', _keySet = keySet'}
  void $ runRWST handle env initCommitState

debug :: String -> CommitService ()
debug s = do
  dbg <- view debugPrint
  liftIO $! dbg $ "[Service|Commit] " ++ s

now :: CommitService UTCTime
now = view getTimestamp >>= liftIO

logMetric :: Metric -> CommitService ()
logMetric m = do
  publishMetric' <- view publishMetric
  liftIO $! publishMetric' m

handle :: CommitService ()
handle = do
  oChan <- view commitChannel
  debug "Launch!"
  forever $ do
    q <- liftIO $ readComm oChan
    case q of
      Tick t -> liftIO (pprintTock t) >>= debug
      ChangeNodeId{..} -> do
        prevNodeId <- use nodeId
        nodeId .= newNodeId
        debug $ "Changed NodeId: " ++ show prevNodeId ++ " -> " ++ show newNodeId
      UpdateKeySet{..} -> do
        keySet %= updateKeySet
        debug "Updated KeySet"
      CommitNewEntries{..} -> do
        debug $ (show . Log.lesCnt $ logEntriesToApply)
              ++ " new log entries to apply, up to "
              ++ show (fromJust $ Log.lesMaxIndex logEntriesToApply)
        applyLogEntries logEntriesToApply
      ReloadFromDisk{..} -> do
        debug $ (show . Log.lesCnt $ logEntriesToApply)
              ++ " entries loaded from disk to apply, up to "
              ++ show (fromJust $ Log.lesMaxIndex logEntriesToApply)
        applyLogEntries logEntriesToApply


applyLogEntries :: LogEntries -> CommitService ()
applyLogEntries les@(LogEntries leToApply) = do
  now' <- now
  results <- mapM (applyCommand now') (Map.elems leToApply)
  commitIndex' <- return $ fromJust $ Log.lesMaxIndex les
  logMetric $ MetricAppliedIndex commitIndex'
  if not (null results)
    then debug $! "Applied " ++ show (length results) ++ " CMD(s)"
    else debug "Applied log entries but did not send results?"

logApplyLatency :: Command -> CommitService ()
logApplyLatency (Command _ _ _ _ provenance) = case provenance of
  NewMsg -> return ()
  ReceivedMsg _digest _orig mReceivedAt -> case mReceivedAt of
    Just (ReceivedAt arrived) -> do
      now' <- now
      logMetric $ MetricApplyLatency $ fromIntegral $ interval arrived now'
    Nothing -> return ()
{-# INLINE logApplyLatency #-}

applyCommand :: UTCTime -> LogEntry -> CommitService ()
applyCommand tEnd le = do
  let cmd = _leCommand le
  apply <- view applyLogEntry
  logApplyLatency cmd
  result <- liftIO $ apply le
  updateCmdStatusMap cmd result tEnd -- shared with the API and to query state

updateCmdStatusMap :: Command -> CommandResult -> UTCTime -> CommitService ()
updateCmdStatusMap cmd cmdResult tEnd = do
  rid <- return $ _cmdRequestId cmd
  lat <- return $ case _pTimeStamp $ _cmdProvenance cmd of
    Nothing -> 1 -- don't want a div by zero error downstream and this is for demo purposes
    Just (ReceivedAt tStart) -> interval tStart tEnd
  hChan <- view historyChannel
  liftIO $! writeComm hChan (History.Update $ Map.fromList [(RequestKey $ getCmdHashOrInvariantError "updateCmdStatusMap" cmd, AppliedCommand cmdResult lat rid)])

-- makeCommandResponse :: UTCTime -> Command -> CommandResult -> CommitService CommandResponse
-- makeCommandResponse tEnd cmd result = do
--   nid <- use nodeId
--   lat <- return $ case _pTimeStamp $ _cmdProvenance cmd of
--     Nothing -> 1 -- don't want a div by zero error downstream and this is for demo purposes
--     Just (ReceivedAt tStart) -> interval tStart tEnd
--   return $ makeCommandResponse' nid cmd result lat
--
