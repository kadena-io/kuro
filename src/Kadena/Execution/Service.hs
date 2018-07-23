{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Execution.Service
  ( initExecutionEnv
  , runExecutionService
  , module Kadena.Execution.Types
  ) where

import Control.Lens hiding (Index)
import Control.Concurrent
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict
import Data.Serialize (decode)

import qualified Data.HashMap.Strict as HashMap
import qualified Data.Map.Strict as Map
import Data.Thyme.Clock
import Data.Maybe (fromJust)
import Data.ByteString (ByteString)
import Data.Aeson (Value)

import qualified Pact.Types.Command as Pact
import Pact.Types.Command ( ExecutionMode(..))
import Pact.Types.Logger (LogRules(..),initLoggers,doLog)

import Kadena.Util.Util (linkAsyncTrack)
import Kadena.Config
import Kadena.Types.PactDB
import Kadena.Config.TMVar
import Kadena.Types.Base
import Kadena.Execution.Types
import Kadena.Types.Metric
import Kadena.Types.Command
import Kadena.Types.Config
import Kadena.Types.KeySet
import Kadena.Types.Log
import Kadena.Types.Dispatch (Dispatch)
import qualified Kadena.Types.Dispatch as D
import qualified Kadena.Types.History as History
import qualified Kadena.Log as Log
import Kadena.Types.Comms (Comms(..))
import Kadena.Command
import Kadena.Event (pprintBeat)
import Kadena.Private.Service (decrypt)
import Kadena.Private.Types (PrivatePlaintext(..),PrivateResult(..))
import Kadena.Execution.Pact
import Kadena.Consensus.Publish
import Kadena.Types.Entity
import qualified Kadena.ConfigChange as CfgChange

initExecutionEnv
  :: Dispatch
  -> (String -> IO ())
  -> PactPersistConfig
  -> LogRules
  -> (Metric -> IO ())
  -> IO UTCTime
  -> GlobalConfigTMVar
  -> EntityConfig
  -> ExecutionEnv
initExecutionEnv dispatch' debugPrint' persistConfig logRules' publishMetric' getTimestamp' gcm' ent = ExecutionEnv
  { _execChannel = dispatch' ^. D.execService
  , _historyChannel = dispatch' ^. D.historyChannel
  , _privateChannel = dispatch' ^. D.privateChannel
  , _pactPersistConfig = persistConfig
  , _debugPrint = debugPrint'
  , _execLoggers = initLoggers debugPrint' doLog logRules'
  , _publishMetric = publishMetric'
  , _getTimestamp = getTimestamp'
  , _mConfig = gcm'
  , _entityConfig = ent
  }

data ReplayStatus = ReplayFromDisk | FreshCommands deriving (Show, Eq)

onUpdateConf :: ExecutionChannel -> Config -> IO ()
onUpdateConf oChan conf@Config{ _nodeId = nodeId' } = do
  writeComm oChan $ ChangeNodeId nodeId'
  writeComm oChan $ UpdateKeySet $ confToKeySet conf


runExecutionService :: ExecutionEnv -> Publish -> NodeId -> KeySet -> IO ()
runExecutionService env pub nodeId' keySet' = do
  cmdExecInter <- initPactService env pub
  initExecutionState <- return $! ExecutionState {
    _csNodeId = nodeId',
    _csKeySet = keySet',
    _csCommandExecInterface = cmdExecInter}
  let cu = ConfigUpdater (env ^. debugPrint) "Service|Execution" (onUpdateConf (env ^. execChannel))
  linkAsyncTrack "ExecutionConfUpdater" $ CfgChange.runConfigUpdater cu (env ^. mConfig)
  void $ runRWST handle env initExecutionState

debug :: String -> ExecutionService ()
debug s = do
  dbg <- view debugPrint
  liftIO $! dbg $ "[Service|Execution] " ++ s

now :: ExecutionService UTCTime
now = view getTimestamp >>= liftIO

logMetric :: Metric -> ExecutionService ()
logMetric m = do
  publishMetric' <- view publishMetric
  liftIO $! publishMetric' m

handle :: ExecutionService ()
handle = do
  oChan <- view execChannel
  debug "Launch!"
  forever $ do
    q <- liftIO $ readComm oChan
    case q of
      Heart t -> liftIO (pprintBeat t) >>= debug
      ChangeNodeId{..} -> do
        prevNodeId <- use csNodeId
        unless (prevNodeId == newNodeId) $ do
          csNodeId .= newNodeId
          debug $ "Changed NodeId: " ++ show prevNodeId ++ " -> " ++ show newNodeId
      UpdateKeySet{..} -> do
        prevKeySet <- use csKeySet
        unless (prevKeySet == newKeySet) $ do
          csKeySet .= newKeySet
          debug $ "Updated keyset"
      ExecuteNewEntries{..} -> do
        debug $ (show . Log.lesCnt $ logEntriesToApply)
              ++ " new log entries to apply, up to "
              ++ show (fromJust $ Log.lesMaxIndex logEntriesToApply)
        applyLogEntries FreshCommands logEntriesToApply
      ReloadFromDisk{..} -> do
        debug $ (show . Log.lesCnt $ logEntriesToApply)
              ++ " entries loaded from disk to apply, up to "
              ++ show (fromJust $ Log.lesMaxIndex logEntriesToApply)
        applyLogEntries ReplayFromDisk logEntriesToApply
      ExecLocal{..} -> applyLocalCommand (localCmd,localResult)
      ExecConfigChange{..} -> applyConfigChange logEntriesToApply

applyLogEntries :: ReplayStatus -> LogEntries -> ExecutionService ()
applyLogEntries rs les@(LogEntries leToApply) = do
  now' <- now
  (results :: [(RequestKey, CommandResult)]) <- mapM (applyCommand now') (Map.elems leToApply)
  commitIndex' <- return $ fromJust $ Log.lesMaxIndex les
  logMetric $ MetricAppliedIndex commitIndex'
  if not (null results)
    then do
      debug $! "Applied " ++ show (length results) ++ " CMD(s)"
      hChan <- view historyChannel
      unless (rs == ReplayFromDisk) $ liftIO $! writeComm hChan (History.Update $ HashMap.fromList results)
    else debug "Applied log entries but did not send results?"

logApplyLatency :: UTCTime -> LogEntry -> ExecutionService ()
logApplyLatency startTime LogEntry{..} = case _leCmdLatMetrics of
  Nothing -> return ()
  Just n ->
    logMetric $ MetricApplyLatency $ fromIntegral $ interval (_lmFirstSeen n) startTime
{-# INLINE logApplyLatency #-}

getPendingPreProcSCC :: UTCTime -> MVar SCCPreProcResult -> ExecutionService SCCPreProcResult
getPendingPreProcSCC startTime mvResult = liftIO (tryReadMVar mvResult) >>= \case
  Just r -> return r
  Nothing -> do
    r <- liftIO $ readMVar mvResult
    endTime <- now
    debug $ "Blocked on Pending Pact PreProc for " ++ printInterval startTime endTime
    return r

getPendingPreProcCCC :: UTCTime -> MVar CCCPreProcResult -> ExecutionService CCCPreProcResult
getPendingPreProcCCC startTime mvResult = liftIO (tryReadMVar mvResult) >>= \case
  Just r -> return r
  Nothing -> do
    r <- liftIO $ readMVar mvResult
    endTime <- now
    debug $ "Blocked on Consensus PreProc for " ++ printInterval startTime endTime
    return r

applyCommand :: UTCTime -> LogEntry -> ExecutionService (RequestKey, CommandResult)
applyCommand _tEnd le@LogEntry{..} = do
  apply <- Pact._ceiApplyPPCmd <$> use csCommandExecInterface
  startTime <- now
  logApplyLatency startTime le
  let chash = getCmdBodyHash _leCommand
      rkey = RequestKey chash
      stamp ppLat = do
        tEnd' <- now
        return $ mkLatResults <$> updateExecutionPreProc startTime tEnd' ppLat
  case _leCommand of
    SmartContractCommand{..} -> do
      (pproc, ppLat) <- case _sccPreProc of
        Unprocessed -> do
          debug $ "WARNING: non-preproccessed command found for " ++ show _leLogIndex
          case (verifyCommand _leCommand) of
            SmartContractCommand{..} -> return $! (result _sccPreProc, _leCmdLatMetrics)
            _ -> error "[applyCommand.1] unreachable exception... and yet reached"
        Pending{..} -> do
          PendingResult{..} <- getPendingPreProcSCC startTime pending
          return $ (_prResult, updateLatPreProc _prStartedPreProc _prFinishedPreProc _leCmdLatMetrics)
        Result{..}  -> do
          debug $ "WARNING: fully resolved pact command found for " ++ show _leLogIndex
          return $! (result, _leCmdLatMetrics)
      result <- liftIO $ apply (Transactional (fromIntegral _leLogIndex)) _sccCmd pproc
      lm <- stamp ppLat
      return ( rkey
             , SmartContractResult
               { _crHash = chash
               , _scrResult = result
               , _crLogIndex = _leLogIndex
               , _crLatMetrics = lm
               })
    ConsensusChangeCommand{..} -> do
      (pproc, ppLat) <- case _cccPreProc of
        Unprocessed -> do
          debug $ "WARNING: non-preproccessed config command found for " ++ show _leLogIndex
          case (verifyCommand _leCommand) of
            ConsensusChangeCommand{..} -> return $! (result _cccPreProc, _leCmdLatMetrics)
            _ -> error "[applyCommand.conf.2] unreachable exception... and yet reached"
        Pending{..} -> do
          PendingResult{..} <- getPendingPreProcCCC startTime pending
          return $ (_prResult, updateLatPreProc _prStartedPreProc _prFinishedPreProc _leCmdLatMetrics)
        Result{..}  -> do
          debug $ "WARNING: fully resolved consensus command found for " ++ show _leLogIndex
          return $! (result, _leCmdLatMetrics)
      gcm <- view mConfig
      result <- liftIO $ CfgChange.mutateGlobalConfig gcm pproc
      lm <- stamp ppLat
      return ( rkey
             , ConsensusChangeResult
               { _crHash = chash
               , _concrResult = result
               , _crLogIndex = _leLogIndex
               , _crLatMetrics = lm
               })
    PrivateCommand Hashed{..} -> do
      pchan <- view privateChannel
      r <- liftIO $ decrypt pchan _hValue
      let finish pr = stamp _leCmdLatMetrics >>= \l ->
            return (rkey, PrivateCommandResult chash pr _leLogIndex l)
      case r of
        Left e -> finish (PrivateFailure (show e))
        Right Nothing -> finish PrivatePrivate
        Right (Just pm) -> do
          pr <- applyPrivate le pm
          case pr of
            Left e -> finish $ PrivateFailure e
            Right cr -> finish $ PrivateSuccess cr

applyPrivate :: LogEntry -> PrivatePlaintext -> ExecutionService (Either String Pact.CommandResult)
applyPrivate LogEntry{..} PrivatePlaintext{..} = case decode _ppMessage of
  Left e -> return $ Left e
  Right cmd -> case Pact.verifyCommand cmd of
    Pact.ProcFail e -> return $ Left e
    p@Pact.ProcSucc {} -> do
      apply <- Pact._ceiApplyPPCmd <$> use csCommandExecInterface
      Right <$> liftIO (apply (Transactional (fromIntegral _leLogIndex)) cmd p)

applyLocalCommand :: (Pact.Command ByteString, MVar Value) -> ExecutionService ()
applyLocalCommand (cmd, mv) = do
  applyLocal <- Pact._ceiApplyCmd <$> use csCommandExecInterface
  cr <- liftIO $ applyLocal Local cmd
  liftIO $ putMVar mv (Pact._crResult cr)

-- | This may be used in the future for configuration changes other than cluster membership changes.
--   Cluster membership changes are implemented via applyCommand
applyConfigChange :: LogEntries -> ExecutionService ()
applyConfigChange _ = debug "[Execution service]: applyConfigChange - not implemented"

updateLatPreProc :: Maybe UTCTime -> Maybe UTCTime -> Maybe CmdLatencyMetrics -> Maybe CmdLatencyMetrics
updateLatPreProc hitPreProc finPreProc = fmap update'
  where
    update' cmd = cmd {_lmHitPreProc = hitPreProc
                      ,_lmFinPreProc = finPreProc}
{-# INLINE updateLatPreProc #-}

updateExecutionPreProc :: UTCTime -> UTCTime -> Maybe CmdLatencyMetrics -> Maybe CmdLatencyMetrics
updateExecutionPreProc hitExecution finExecution = fmap update'
  where
    update' cmd = cmd {_lmHitExecution = Just hitExecution
                      ,_lmFinExecution = Just finExecution}
{-# INLINE updateExecutionPreProc #-}
