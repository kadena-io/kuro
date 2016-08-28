{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Kadena.Spec.Simple
  ( runServer
  , runClient
  , RequestId
  , CommandStatus
  ) where

import Control.AutoUpdate (mkAutoUpdate, defaultUpdateSettings,updateAction,updateFreq)
import Control.Concurrent (modifyMVar_, MVar, newEmptyMVar)
import qualified Control.Concurrent.Chan.Unagi as Unagi
import qualified Control.Concurrent.Lifted as CL
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class

import Data.Monoid ((<>))
import Data.Thyme.Calendar (showGregorian)
import Data.Thyme.Clock (UTCTime, getCurrentTime)
import Data.Thyme.LocalTime
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Yaml as Y

import System.Console.GetOpt
import System.Environment
import System.Exit
import System.IO (BufferMode(..),stdout,stderr,hSetBuffering)
import System.Log.FastLogger
import System.Random

import Kadena.Consensus.Server
import Kadena.Consensus.Client
import Kadena.Types.Command
import Kadena.Types.Base
import Kadena.Types.Config
import Kadena.Types.Spec hiding (timeCache)
import Kadena.Types.Message.CMD
import Kadena.Types.Metric
import Kadena.Types.Dispatch
import Kadena.Util.Util (awsDashVar)
import Kadena.Messaging.ZMQ
import Kadena.Monitoring.Server (startMonitoring)
import Kadena.Runtime.Api.ApiServer
import qualified Kadena.Runtime.MessageReceiver as RENV
import Kadena.Command.CommandLayer
import Kadena.Command.Types

data Options = Options
  {  optConfigFile :: FilePath
   , optApiPort :: Int
   , optDisablePersistence :: Bool
  } deriving Show

defaultOptions :: Options
defaultOptions = Options { optConfigFile = "", optApiPort = -1, optDisablePersistence = False}

options :: [OptDescr (Options -> Options)]
options =
  [ Option ['c']
           ["config"]
           (ReqArg (\fp opts -> opts { optConfigFile = fp }) "CONF_FILE")
           "Configuration File"
  , Option ['p']
           ["apiPort"]
           (ReqArg (\p opts -> opts { optApiPort = read p }) "API_PORT")
           "Api Port"
  , Option ['d']
           ["disablePersistence"]
           (OptArg (\_ opts -> opts { optDisablePersistence = True }) "DISABLE_PERSISTENCE" )
            "Disable Persistence"
  ]

getConfig :: IO Config
getConfig = do
  argv <- getArgs
  case getOpt Permute options argv of
    (o,_,[]) -> do
      opts <- return $ foldl (flip id) defaultOptions o
      conf <- Y.decodeFileEither $ optConfigFile opts
      case conf of
        Left err -> putStrLn (Y.prettyPrintParseException err) >> exitFailure
        Right conf' -> return $ conf'
          { _apiPort = if optApiPort opts == -1 then conf' ^. apiPort else optApiPort opts
          , _logSqlitePath = if optDisablePersistence opts then "" else conf' ^. logSqlitePath
          }
    (_,_,errs)     -> mapM_ putStrLn errs >> exitFailure

showDebug :: TimedFastLogger -> String -> IO ()
showDebug fs m = fs (\t -> toLogStr t <> " " <> toLogStr (BSC.pack m) <> "\n")

noDebug :: String -> IO ()
noDebug _ = return ()

timeCache :: TimeZone -> IO UTCTime -> IO (IO FormattedTime)
timeCache tz tc = mkAutoUpdate defaultUpdateSettings
  { updateAction = do
      t' <- tc
      (ZonedTime (LocalTime d t) _) <- return $ view zonedTime (tz,t')
      return $ BSC.pack $ showGregorian d ++ "T" ++ take 12 (show t)
  , updateFreq = 1000}

utcTimeCache :: IO (IO UTCTime)
utcTimeCache = mkAutoUpdate defaultUpdateSettings
  { updateAction = getCurrentTime
  , updateFreq = 1000}

initSysLog :: IO UTCTime -> IO TimedFastLogger
initSysLog tc = do
  tz <- getCurrentTimeZone
  fst <$> newTimedFastLogger (join $ timeCache tz tc) (LogStdout defaultBufSize)

simpleConsensusSpec :: ApplyFn
               -> (String -> IO ())
               -> (Metric -> IO ())
               -> (MVar CommandMap -> RequestId -> CommandStatus -> IO ())
               -> CommandMVarMap
               -> Unagi.OutChan (RequestId, [CommandEntry]) --IO (RequestId, [CommandEntry])
               -> ConsensusSpec
simpleConsensusSpec applyFn debugFn pubMetricFn updateMapFn cmdMVarMap getCommands = ConsensusSpec
    {
      -- apply log entries to the state machine, given by caller
      _applyLogEntry   = applyFn
      -- use the debug function given by the caller
    , _debugPrint      = debugFn
      -- publish a 'Metric' to EKG
    , _publishMetric   = pubMetricFn
      -- get the current time in UTC
    , _getTimestamp = liftIO getCurrentTime
     -- _random :: forall a . Random a => (a, a) -> m a
    , _random = liftIO . randomRIO
    -- _enqueue :: InChan (Event nt et rt) -> Event nt et rt -> m ()
    , _updateCmdMap = updateMapFn

    , _cmdStatusMap = cmdMVarMap

    , _dequeueFromApi = liftIO $ Unagi.readChan getCommands
    }

simpleReceiverEnv :: Dispatch
                  -> Config
                  -> (String -> IO ())
                  -> MVar String
                  -> RENV.ReceiverEnv
simpleReceiverEnv dispatch conf debugFn restartTurbo' = RENV.ReceiverEnv
  dispatch
  (KeySet (view publicKeys conf) (view clientPublicKeys conf))
  debugFn
  restartTurbo'

updateCmdMapFn :: MonadIO m => MVar CommandMap -> RequestId -> CommandStatus -> m ()
updateCmdMapFn cmdMapMvar rid cmdStatus =
    liftIO (modifyMVar_ cmdMapMvar
     (\(CommandMap nextRid map') ->
          return $ CommandMap nextRid (Map.insert rid cmdStatus map')
     )
    )

setLineBuffering :: IO ()
setLineBuffering = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering

resetAwsEnv :: Bool -> IO ()
resetAwsEnv awsEnabled = do
  awsDashVar awsEnabled "Role" "Startup"
  awsDashVar awsEnabled "Term" "Startup"
  awsDashVar awsEnabled "AppliedIndex" "Startup"
  awsDashVar awsEnabled "CommitIndex" "Startup"

runClient :: (Command -> IO CommandResult) -> IO (RequestId, [CommandEntry]) -> CommandMVarMap -> MVar Bool -> IO ()
runClient _applyFn getEntries cmdStatusMap' disableTimeouts = do
  setLineBuffering
  rconf <- getConfig
  resetAwsEnv (rconf ^. enableAwsIntegration)
  utcTimeCache' <- utcTimeCache
  fs <- initSysLog utcTimeCache'
  let debugFn = if rconf ^. enableDebug then showDebug fs else noDebug
  pubMetric <- startMonitoring rconf
  dispatch <- initDispatch
  me <- return $ rconf ^. nodeId
  oNodes <- return $ Set.toList $ Set.delete me $ Set.union (rconf ^. otherNodes) (Map.keysSet $ rconf ^. clientPublicKeys)
  runMsgServer dispatch me oNodes debugFn -- ZMQ
  -- STUBs mocking
  (_, stubGetApiCommands) <- Unagi.newChan
  let raftSpec = simpleConsensusSpec
                   (const (return $ CommandResult ""))
                   debugFn
                   (liftIO . pubMetric)
                   updateCmdMapFn
                   cmdStatusMap'
                   stubGetApiCommands
  restartTurbo <- newEmptyMVar
  let receiverEnv = simpleReceiverEnv dispatch rconf debugFn restartTurbo
  runConsensusClient receiverEnv getEntries cmdStatusMap' rconf raftSpec disableTimeouts utcTimeCache'

-- | sets up and runs both API and raft protocol
--   shared state between API and protocol: sharedCmdStatusMap
--   comminication channel btw API and protocol:
--   [API write/place command -> toCommands] [getApiCommands -> kadena read/poll command]
runServer :: IO ()
runServer = do
  setLineBuffering
  (toCommands, getApiCommands) <- Unagi.newChan
  sharedCmdStatusMap <- initCommandMap
  rconf <- getConfig
  (applyFn,_) <- initCommandLayer (CommandConfig (_entity rconf))
  resetAwsEnv (rconf ^. enableAwsIntegration)
  me <- return $ rconf ^. nodeId
  oNodes <- return $ Set.toList $ Set.delete me $ Set.union (rconf ^. otherNodes) (Map.keysSet $ rconf ^. clientPublicKeys)
  dispatch <- initDispatch
  -- Start The Api Server, communicates with the Kadena protocol via sharedCmdStatusMap
  -- API interface will run on 800{nodeNum} for now, where the nodeNum for 10003 is 3
  let myApiPort = rconf ^. apiPort -- passed in on startup (default 8000): `--apiPort 8001`
  void $ CL.fork $ runApiServer toCommands sharedCmdStatusMap myApiPort

  utcTimeCache' <- utcTimeCache
  fs <- initSysLog utcTimeCache'
  let debugFn = if rconf ^. enableDebug then showDebug fs else noDebug

  -- each node has its own snap monitoring server
  pubMetric <- startMonitoring rconf
  runMsgServer dispatch me oNodes debugFn -- ZMQ
  let raftSpec = simpleConsensusSpec
                   (liftIO . applyFn)
                   debugFn
                   (liftIO . pubMetric)
                   updateCmdMapFn
                   sharedCmdStatusMap
                   getApiCommands
  restartTurbo <- newEmptyMVar
  let receiverEnv = simpleReceiverEnv dispatch rconf debugFn restartTurbo
  runConsensusServer receiverEnv rconf raftSpec utcTimeCache'