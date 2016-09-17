{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Consensus.Commit
  ( initCommitEnv
  , runCommitService
  ) where

import Control.Lens hiding (Index, (|>))
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict

import qualified Data.Map.Strict as Map
import Data.Thyme.Clock
-- import Data.Int (Int64)
import Data.Maybe (fromJust)

import Kadena.Types.Service.Commit
import Kadena.Types.Dispatch
import qualified Kadena.Service.Log as Log


-- TODO: delete SendResponse from Sender

initCommitEnv
  :: Dispatch
  -> (String -> IO ())
  -> ApplyFn
  -> (Metric -> IO ())
  -> IO UTCTime
  -> (AppliedCommand -> IO ())
  -> CommitEnv
initCommitEnv dispatch' debugPrint' applyLogEntry'
              publishMetric' getTimestamp' publishResults' = CommitEnv
  { _commitChannel = dispatch' ^. commitService
  , _applyLogEntry = applyLogEntry'
  , _debugPrint = debugPrint'
  , _publishMetric = publishMetric'
  , _getTimestamp = getTimestamp'
  , _publishResults = publishResults'
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
{-# INLINE now #-}

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
      CommitNewEntries{..} -> applyLogEntries logEntriesToApply

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
  pubResults <- view publishResults
  liftIO $! pubResults (AppliedCommand cmdResult lat rid)

-- makeCommandResponse :: UTCTime -> Command -> CommandResult -> CommitService CommandResponse
-- makeCommandResponse tEnd cmd result = do
--   nid <- use nodeId
--   lat <- return $ case _pTimeStamp $ _cmdProvenance cmd of
--     Nothing -> 1 -- don't want a div by zero error downstream and this is for demo purposes
--     Just (ReceivedAt tStart) -> interval tStart tEnd
--   return $ makeCommandResponse' nid cmd result lat
--
-- makeCommandResponse' :: NodeId -> Command -> CommandResult -> Int64 -> CommandResponse
-- makeCommandResponse' nid Command{..} result lat = CommandResponse
--              result
--              nid
--              _cmdRequestId
--              lat
--              NewMsg
