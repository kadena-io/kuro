{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Juno.Spec.Simple
  ( runJuno
  , runClient
  , RequestId
  , CommandStatus
  ) where

import Juno.Consensus.Server
import qualified Juno.Runtime.MessageReceiver as RENV
import Juno.Consensus.Client
import Juno.Types
import Juno.Messaging.ZMQ
import Juno.Monitoring.Server (startMonitoring)
import Juno.Runtime.Api.ApiServer

-- import System.Process (system)
-- import Control.Concurrent (forkIO)
import System.IO (BufferMode(..),stdout,stderr,hSetBuffering)
import Control.Lens
import Control.Monad
import Control.Concurrent (modifyMVar_, MVar)
import qualified Control.Concurrent.Lifted as CL
import qualified Control.Concurrent.Chan.Unagi as Unagi

import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map as Map
import Data.Monoid ((<>))
import Data.Thyme.Calendar (showGregorian)
import Data.Thyme.Clock (getCurrentTime)
import Data.Thyme.LocalTime

import System.Console.GetOpt
import System.Environment
import System.Exit
import System.Log.FastLogger
import Control.AutoUpdate (mkAutoUpdate, defaultUpdateSettings,updateAction,updateFreq)


import Control.Monad.IO.Class

import qualified Data.Yaml as Y

import System.Random

data Options = Options
  {  optConfigFile :: FilePath
   , optApiPort :: Int
  } deriving Show

defaultOptions :: Options
defaultOptions = Options { optConfigFile = "", optApiPort = 8000 }

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
        Right conf' -> do
          let apiPort' = optApiPort opts
          return $ apiPort .~ apiPort' $ conf'
    (_,_,errs)     -> mapM_ putStrLn errs >> exitFailure

showDebug' :: TimedFastLogger -> String -> IO ()
showDebug' fs m = fs (\t -> (toLogStr t) <> " " <> (toLogStr $ BSC.pack $ m) <> "\n")

showDebug :: TimedFastLogger -> NodeId -> String -> IO ()
showDebug fs _ msg = showDebug' fs msg

noDebug :: NodeId -> String -> IO ()
noDebug _ _ = return ()

getSysLogTime :: IO (FormattedTime)
getSysLogTime = do
  (ZonedTime (LocalTime d t) _) <- getZonedTime
  return $ BSC.pack $ (showGregorian d) ++ "T" ++ (take 12 $ show t)

timeCache :: IO (IO FormattedTime)
timeCache = mkAutoUpdate defaultUpdateSettings
  {  updateAction = getSysLogTime
  ,  updateFreq = 1000 -- every millisecond
  }

initSysLog :: IO (TimedFastLogger)
initSysLog = fst <$> newTimedFastLogger (join timeCache) (LogStdout defaultBufSize)

simpleRaftSpec :: (Command -> IO CommandResult)
               -> (NodeId -> String -> IO ())
               -> (Metric -> IO ())
               -> (MVar CommandMap -> RequestId -> CommandStatus -> IO ())
               -> CommandMVarMap
               -> Unagi.OutChan (RequestId, [(Maybe Alias, CommandEntry)]) --IO (RequestId, [CommandEntry])
               -> RaftSpec
simpleRaftSpec applyFn debugFn pubMetricFn updateMapFn cmdMVarMap getCommands = RaftSpec
    {
      -- TODO don't read log entries
      _readLogEntry    = return . const Nothing
      -- TODO don't write log entries
    , _writeLogEntry   = \_ _ -> return ()
      -- TODO always read startTerm
    , _readTermNumber  = return startTerm
      -- TODO don't write term numbers
    , _writeTermNumber = return . const ()
      -- TODO never voted for anyone
    , _readVotedFor    = return Nothing
      -- TODO don't record votes
    , _writeVotedFor   = return . const ()
      -- apply log entries to the state machine, given by caller
    , _applyLogEntry   = applyFn
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
                  -> RENV.ReceiverEnv
simpleReceiverEnv dispatch conf debugFn = RENV.ReceiverEnv
  dispatch
  (KeySet (view publicKeys conf) (view clientPublicKeys conf))
  debugFn

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

awsDashVar :: String -> String -> IO ()
awsDashVar _ _ = return ()
--awsDashVar k v = void $ forkIO $ void $ system $
--  "aws ec2 create-tags --resources `ec2-metadata --instance-id | sed 's/^.*: //g'` --tags Key="
--  ++ k
--  ++ ",Value="
--  ++ v
--  ++ " >/dev/null"

resetAwsEnv :: IO ()
resetAwsEnv = do
  awsDashVar "Role" "Startup"
  awsDashVar "Term" "Startup"
  awsDashVar "AppliedIndex" "Startup"
  awsDashVar "CommitIndex" "Startup"

nodeIDtoAddr :: NodeId -> Addr String
nodeIDtoAddr (NodeId _ _ a _) = Addr $ a

runClient :: (Command -> IO CommandResult) -> IO (RequestId, [(Maybe Alias, CommandEntry)]) -> CommandMVarMap -> IO ()
runClient applyFn getEntries cmdStatusMap' = do
  setLineBuffering
  resetAwsEnv
  rconf <- getConfig
  fs <- initSysLog
  let debugFn = if (rconf ^. enableDebug) then showDebug fs else noDebug
  let debugFn' = if (rconf ^. enableDebug) then showDebug' fs else (\_ -> return ())
  pubMetric <- startMonitoring rconf
  dispatch <- initDispatch
  me <- return $ nodeIDtoAddr $ rconf ^. nodeId
  runMsgServer dispatch me [] debugFn' -- ZMQ
  -- STUBs mocking
  (_, stubGetApiCommands) <- Unagi.newChan
  let raftSpec = simpleRaftSpec
                   (liftIO . applyFn)
                   (debugFn)
                   (liftIO . pubMetric)
                   updateCmdMapFn
                   cmdStatusMap'
                   stubGetApiCommands
  let receiverEnv = simpleReceiverEnv dispatch rconf debugFn'
  runRaftClient receiverEnv getEntries cmdStatusMap' rconf raftSpec

-- | sets up and runs both API and raft protocol
--   shared state between API and protocol: sharedCmdStatusMap
--   comminication channel btw API and protocol:
--   [API write/place command -> toCommands] [getApiCommands -> juno read/poll command]
runJuno :: (Command -> IO CommandResult) -> Unagi.InChan (RequestId, [(Maybe Alias, CommandEntry)])
        -> Unagi.OutChan (RequestId, [(Maybe Alias, CommandEntry)]) -> CommandMVarMap -> IO ()
runJuno applyFn toCommands getApiCommands sharedCmdStatusMap = do
  setLineBuffering
  resetAwsEnv
  rconf <- getConfig
  me <- return $ nodeIDtoAddr $ rconf ^. nodeId
  dispatch <- initDispatch
  -- Start The Api Server, communicates with the Juno protocol via sharedCmdStatusMap
  -- API interface will run on 800{nodeNum} for now, where the nodeNum for 10003 is 3
  let myApiPort = rconf ^. apiPort -- passed in on startup (default 8000): `--apiPort 8001`
  void $ CL.fork $ runApiServer toCommands sharedCmdStatusMap myApiPort

  fs <- initSysLog
  let debugFn = if (rconf ^. enableDebug) then showDebug fs else noDebug
  let debugFn' = if (rconf ^. enableDebug) then showDebug' fs else (\_ -> return ())

  -- each node has its own snap monitoring server
  pubMetric <- startMonitoring rconf
  runMsgServer dispatch me [] debugFn' -- ZMQ
  let raftSpec = simpleRaftSpec
                   (liftIO . applyFn)
                   (debugFn)
                   (liftIO . pubMetric)
                   updateCmdMapFn
                   sharedCmdStatusMap
                   getApiCommands
  let receiverEnv = simpleReceiverEnv dispatch rconf debugFn'
  runRaftServer receiverEnv rconf raftSpec
