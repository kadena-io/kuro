{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Commit.Service
  ( initCommitEnv
  , runCommitService
  , module X
  ) where

import Control.Lens hiding (Index, (|>))
import Control.Concurrent
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict

import qualified Data.HashMap.Strict as HashMap
import qualified Data.Map.Strict as Map
import Data.Thyme.Clock
import Data.Maybe (fromJust)
import Data.ByteString (ByteString)
import Data.Aeson (Value)

import System.Directory

import qualified Pact.Types.Command as Pact
import Pact.Types.Command (CommandExecInterface(..), ExecutionMode(..),ParsedCode(..))
import Pact.Types.Runtime (EntityName)
import Pact.Types.RPC (PactRPC,PactConfig(..))
import Pact.Server.PactService (applyCmd)
import Pact.Types.Server (CommandState(..))
import Pact.PersistPactDb (initDbEnv,pactdb)
import Pact.Types.Logger (LogRules(..),initLoggers,doLog,logLog,Logger,Loggers,newLogger)
import Pact.Interpreter (initSchema,initRefStore,PactDbEnv(..))
import qualified Pact.Persist.SQLite as SQLite
import qualified Pact.Persist.Pure as Pure
import qualified Pact.Persist.MSSQL as MSSQL
import Pact.Persist.CacheAdapter (initPureCacheWB)
import Pact.Persist (Persister)
import qualified Pact.Persist.WriteBehind as WB

import Kadena.Util.Util (linkAsyncTrack)
import qualified Kadena.Types.Config as Config
import Kadena.Commit.Types as X
import Kadena.Types.Dispatch (Dispatch)
import qualified Kadena.Types.Dispatch as D
import qualified Kadena.History.Types as History
import qualified Kadena.Log.Service as Log

initCommitEnv
  :: Dispatch
  -> (String -> IO ())
  -> PactPersistConfig
  -> EntityName
  -> LogRules
  -> (Metric -> IO ())
  -> IO UTCTime
  -> Config.GlobalConfigTMVar
  -> CommitEnv
initCommitEnv dispatch' debugPrint' persistConfig entName logRules' publishMetric' getTimestamp' gcm' = CommitEnv
  { _commitChannel = dispatch' ^. D.commitService
  , _historyChannel = dispatch' ^. D.historyChannel
  , _pactPersistConfig = persistConfig
  , _pactConfig = PactConfig entName
  , _debugPrint = debugPrint'
  , _commitLoggers = initLoggers debugPrint' doLog logRules'
  , _publishMetric = publishMetric'
  , _getTimestamp = getTimestamp'
  , _mConfig = gcm'
  }

data ReplayStatus = ReplayFromDisk | FreshCommands deriving (Show, Eq)

onUpdateConf :: CommitChannel -> Config.Config -> IO ()
onUpdateConf oChan conf@Config.Config{ _nodeId = nodeId' } = do
  writeComm oChan $ ChangeNodeId nodeId'
  writeComm oChan $ UpdateKeySet $ Config.confToKeySet conf

logInit :: Logger -> String -> IO ()
logInit l = logLog l "INIT"

initPactService :: CommitEnv -> IO (CommandExecInterface (PactRPC ParsedCode))
initPactService CommitEnv{..} = do
  let PactPersistConfig{..} = _pactPersistConfig
      logger = newLogger _commitLoggers "PactService"
      initCI = initCommandInterface logger _commitLoggers _pactConfig
      initWB p db = if _ppcWriteBehind
        then do
          wb <- initPureCacheWB p db  _commitLoggers
          linkAsyncTrack "WriteBehindThread" (WB.runWBService wb)
          initCI WB.persister wb
        else initCI p db
  case _ppcBackend of
    PPBInMemory -> do
      logInit logger "Initializing pure pact"
      initCI Pure.persister Pure.initPureDb
    PPBSQLite conf@SQLite.SQLiteConfig{..} -> do
      dbExists <- doesFileExist dbFile
      when dbExists $ logInit logger "Deleting Existing Pact DB File" >> removeFile dbFile
      logInit logger "Initializing SQLite"
      initWB SQLite.persister =<< SQLite.initSQLite conf _commitLoggers
    PPBMSSQL conf connStr -> do
      logInit logger "Initializing MSSQL"
      initWB MSSQL.persister =<< MSSQL.initMSSQL connStr conf _commitLoggers

initCommandInterface :: Logger -> Loggers -> PactConfig -> Persister w -> w -> IO (CommandExecInterface (PactRPC ParsedCode))
initCommandInterface logger loggers pconf p db = do
  pde <- PactDbEnv pactdb <$> newMVar (initDbEnv loggers p db)
  cmdVar <- newMVar (CommandState initRefStore)
  logInit logger "Creating Pact Schema"
  initSchema pde
  return CommandExecInterface
    { _ceiApplyCmd = \eMode cmd -> applyCmd logger pconf pde cmdVar eMode cmd (Pact.verifyCommand cmd)
    , _ceiApplyPPCmd = applyCmd logger pconf pde cmdVar }


runCommitService :: CommitEnv -> NodeId -> KeySet -> IO ()
runCommitService env nodeId' keySet' = do
  cmdExecInter <- initPactService env
  initCommitState <- return $! CommitState { _nodeId = nodeId', _keySet = keySet', _commandExecInterface = cmdExecInter}
  let cu = Config.ConfigUpdater (env ^. debugPrint) "Service|Commit" (onUpdateConf (env ^. commitChannel))
  linkAsyncTrack "CommitConfUpdater" $ runConfigUpdater cu (env ^. mConfig)
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
      Heart t -> liftIO (pprintBeat t) >>= debug
      ChangeNodeId{..} -> do
        prevNodeId <- use nodeId
        unless (prevNodeId == newNodeId) $ do
          nodeId .= newNodeId
          debug $ "Changed NodeId: " ++ show prevNodeId ++ " -> " ++ show newNodeId
      UpdateKeySet{..} -> do
        prevKeySet <- use keySet
        unless (prevKeySet == newKeySet) $ do
          keySet .= newKeySet
          debug $ "Updated keyset"
      CommitNewEntries{..} -> do
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

applyLogEntries :: ReplayStatus -> LogEntries -> CommitService ()
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

logApplyLatency :: UTCTime -> LogEntry -> CommitService ()
logApplyLatency startTime LogEntry{..} = case _leCmdLatMetrics of
  Nothing -> return ()
  Just n -> do
    logMetric $ MetricApplyLatency $ fromIntegral $ interval (_lmFirstSeen n) startTime
{-# INLINE logApplyLatency #-}

getPendingPreProcSCC :: UTCTime -> MVar SCCPreProcResult -> CommitService SCCPreProcResult
getPendingPreProcSCC startTime mvResult = liftIO (tryReadMVar mvResult) >>= \case
  Just r -> return r
  Nothing -> do
    r <- liftIO $ readMVar mvResult
    endTime <- now
    debug $ "Blocked on Pending Pact PreProc for " ++ printInterval startTime endTime
    return r

getPendingPreProcCCC :: UTCTime -> MVar CCCPreProcResult -> CommitService CCCPreProcResult
getPendingPreProcCCC startTime mvResult = liftIO (tryReadMVar mvResult) >>= \case
  Just r -> return r
  Nothing -> do
    r <- liftIO $ readMVar mvResult
    endTime <- now
    debug $ "Blocked on Consensus PreProc for " ++ printInterval startTime endTime
    return r

applyCommand :: UTCTime -> LogEntry -> CommitService (RequestKey, CommandResult)
applyCommand _tEnd le@LogEntry{..} = do
  apply <- Pact._ceiApplyPPCmd <$> use commandExecInterface
  startTime <- now
  logApplyLatency startTime le
  case _leCommand of
    SmartContractCommand{..} -> do
      (pproc, ppLat) <- case _sccPreProc of
        Unprocessed -> do
          debug $ "WARNING: non-preproccessed command found for " ++ show _leLogIndex
          case (History.verifyCommand _leCommand) of
            SmartContractCommand{..} -> return $! (result _sccPreProc, _leCmdLatMetrics)
            _ -> error "[applyCommand.1] unreachable exception... and yet reached"
        Pending{..} -> do
          PendingResult{..} <- getPendingPreProcSCC startTime pending
          return $ (_prResult, updateLatPreProc _prStartedPreProc _prFinishedPreProc _leCmdLatMetrics)
        Result{..}  -> do
          debug $ "WARNING: fully resolved pact command found for " ++ show _leLogIndex
          return $! (result, _leCmdLatMetrics)
      result <- liftIO $ apply (Transactional (fromIntegral _leLogIndex)) _sccCmd pproc
      tEnd' <- now
      lat <- return $ updateCommitPreProc startTime tEnd' ppLat
      return ( RequestKey $ getCmdBodyHash _leCommand
             , SmartContractResult
               { _scrHash = getCmdBodyHash _leCommand
               , _scrResult = result
               , _cmdrLogIndex = _leLogIndex
               , _cmdrLatMetrics = mkLatResults <$> lat
               })
    ConsensusConfigCommand{..} -> do
      (pproc, ppLat) <- case _cccPreProc of
        Unprocessed -> do
          debug $ "WARNING: non-preproccessed config command found for " ++ show _leLogIndex
          case (History.verifyCommand _leCommand) of
            ConsensusConfigCommand{..} -> return $! (result _cccPreProc, _leCmdLatMetrics)
            _ -> error "[applyCommand.conf.2] unreachable exception... and yet reached"
        Pending{..} -> do
          PendingResult{..} <- getPendingPreProcCCC startTime pending
          return $ (_prResult, updateLatPreProc _prStartedPreProc _prFinishedPreProc _leCmdLatMetrics)
        Result{..}  -> do
          debug $ "WARNING: fully resolved consensus command found for " ++ show _leLogIndex
          return $! (result, _leCmdLatMetrics)
      gcm <- view mConfig
      result <- liftIO $ mutateConfig gcm pproc
      tEnd' <- now
      lat <- return $ updateCommitPreProc startTime tEnd' ppLat
      return ( RequestKey $ getCmdBodyHash _leCommand
             , ConsensusConfigResult
               { _ccrHash = getCmdBodyHash _leCommand
               , _ccrResult = result
               , _cmdrLogIndex = _leLogIndex
               , _cmdrLatMetrics = mkLatResults <$> lat
               })

applyLocalCommand :: (Pact.Command ByteString, MVar Value) -> CommitService ()
applyLocalCommand (cmd, mv) = do
  applyLocal <- Pact._ceiApplyCmd <$> use commandExecInterface
  cr <- liftIO $ applyLocal Local cmd
  liftIO $ putMVar mv (Pact._crResult cr)

updateLatPreProc :: Maybe UTCTime -> Maybe UTCTime -> Maybe CmdLatencyMetrics -> Maybe CmdLatencyMetrics
updateLatPreProc hitPreProc finPreProc = fmap update'
  where
    update' cmd = cmd {_lmHitPreProc = hitPreProc
                      ,_lmFinPreProc = finPreProc}
{-# INLINE updateLatPreProc #-}

updateCommitPreProc :: UTCTime -> UTCTime -> Maybe CmdLatencyMetrics -> Maybe CmdLatencyMetrics
updateCommitPreProc hitCommit finCommit = fmap update'
  where
    update' cmd = cmd {_lmHitCommit = Just hitCommit
                      ,_lmFinCommit = Just finCommit}
{-# INLINE updateCommitPreProc #-}
