{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}

module Kadena.Spec.Simple
  ( runServer
  , RequestId
  ) where

import Control.AutoUpdate (mkAutoUpdate, defaultUpdateSettings,updateAction,updateFreq)
import Control.Concurrent
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class

import Data.Maybe
import Data.Monoid ((<>))
import Data.Thyme.Calendar (showGregorian)
import Data.Thyme.Clock (UTCTime, getCurrentTime)
import Data.Thyme.LocalTime
import qualified Data.ByteString.Char8 as BSC

import qualified Data.Set as Set
import qualified Data.Yaml as Y
import qualified Data.Text.IO as T

import System.Console.GetOpt
import System.Environment
import System.Exit
import System.IO (BufferMode(..),stdout,stderr,hSetBuffering)
import System.Log.FastLogger
import System.Random

import qualified Kadena.Config.ClusterMembership as CM
import Kadena.Config.TMVar
import Kadena.Consensus.Service
import Kadena.Types.Base
import Kadena.Crypto
import Kadena.Types.Spec hiding (timeCache)
import Kadena.Types.Metric
import Kadena.Types.Dispatch
import Kadena.Util.Util (awsDashVar, linkAsyncTrack)
import Kadena.Messaging.ZMQ
import Kadena.Monitoring.Server (startMonitoring)
import Kadena.Private.Service (runPrivateService)
import Kadena.Types.Turbine (ReceiverEnv(..))

data Options = Options
  {  optConfigFile :: FilePath
   , optDisablePersistence :: Bool
   , optEnableDiagnostics :: Bool
  } deriving Show

defaultOptions :: Options
defaultOptions = Options { optConfigFile = ""
                         , optDisablePersistence = False
                         , optEnableDiagnostics = False }

options :: [OptDescr (Options -> Options)]
options =
  [ Option ['c']
           ["config"]
           (ReqArg (\fp opts -> opts { optConfigFile = fp }) "CONF_FILE")
           "Configuration File"
  , Option ['d']
           ["disablePersistence"]
           (OptArg (\_ opts -> opts { optDisablePersistence = True }) "DISABLE_PERSISTENCE" )
            "Disable Persistence (run entirely in memory)"
  , Option ['e']
           ["enableDiagnostics"]
           (NoArg (\opts -> opts {optEnableDiagnostics = True }))
           "Enable diagnositc excpetions to be thrown"
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
          { _enablePersistence = not $ optDisablePersistence opts
          -- enableDiagnositcs is set to true if either:
          --   enableDiagnostics is set to true in the config file
          --   or, if the -e flag exists in the command line arg
          , _enableDiagnostics = Just $ (fromMaybe False  (_enableDiagnostics conf')) || (optEnableDiagnostics opts)
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
  , updateFreq = 5}

initSysLog :: IO UTCTime -> IO TimedFastLogger
initSysLog tc = do
  tz <- getCurrentTimeZone
  theCfg <- getConfig
  let logFileName = "log/" ++ show (_alias (_nodeId theCfg)) ++ ".log" -- toto: config?
  fst <$> newTimedFastLogger (join $ timeCache tz tc) (LogFileNoRotate logFileName defaultBufSize)

simpleConsensusSpec
  :: (String -> IO ())
  -> (Metric -> IO ())
  -> ConsensusSpec
simpleConsensusSpec debugFn pubMetricFn = ConsensusSpec
  { _debugPrint      = debugFn
  , _publishMetric = pubMetricFn
  , _getTimestamp = liftIO getCurrentTime
  , _random = liftIO . randomRIO
  }

simpleReceiverEnv :: Dispatch
                  -> Config
                  -> (String -> IO ())
                  -> MVar String
                  -> ReceiverEnv
simpleReceiverEnv dispatch conf debugFn restartTurbo' = ReceiverEnv
  dispatch
  (KeySet (view publicKeys conf))
  debugFn
  restartTurbo'

setLineBuffering :: IO ()
setLineBuffering = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering

_resetAwsEnv :: Bool -> IO ()
_resetAwsEnv awsEnabled = do
  awsDashVar awsEnabled "Role" "Startup"
  awsDashVar awsEnabled "Term" "Startup"
  awsDashVar awsEnabled "AppliedIndex" "Startup"
  awsDashVar awsEnabled "CommitIndex" "Startup"

runServer :: IO ()
runServer = do
  setLineBuffering
  T.putStrLn $! "Kadena LLC (c) (2016-2018)"
  rconf <- getConfig
  gcm <- initGlobalConfigTMVar rconf
#if WITH_KILL_SWITCH || WITH_AWS_KILL_SWITCH
  killSwitchNodeCheck rconf
#endif

  utcTimeCache' <- utcTimeCache
  fs <- initSysLog utcTimeCache'
  let debugFn = if rconf ^. enableDebug then showDebug fs else noDebug
  -- resetAwsEnv (rconf ^. enableAwsIntegration)
  me <- return $ rconf ^. nodeId
  let members = rconf ^. clusterMembers
  oNodes <- return $ Set.toList $ Set.delete me (CM.otherNodes members)-- (Map.keysSet $ rconf ^. clientPublicKeys)
  dispatch <- initDispatch

 -- Each node has its own snap monitoring server
  pubMetric <- startMonitoring rconf
  linkAsyncTrack "ZmqServerThread" $ runMsgServer dispatch me oNodes debugFn gcm
  linkAsyncTrack "PrivateThread" $ runPrivateService dispatch rconf debugFn (_entity rconf)
  let raftSpec = simpleConsensusSpec debugFn (liftIO . pubMetric)

  restartTurbo <- newEmptyMVar
  receiverEnv <- return $ simpleReceiverEnv dispatch rconf debugFn restartTurbo
  timerTarget' <- newEmptyMVar
  rstate <- return $ initialConsensusState timerTarget'
  mPubConsensus' <- newMVar $! PublishedConsensus Nothing Follower startTerm Set.empty
  runConsensusService receiverEnv gcm raftSpec rstate getCurrentTime mPubConsensus'

#if WITH_KILL_SWITCH
_isBetaKillSwitch :: Bool
_isBetaKillSwitch = True
#else
_isBetaKillSwitch :: Bool
_isBetaKillSwitch = False
#endif

#if WITH_AWS_KILL_SWITCH
_isAWSKillSwitch :: Bool
_isAWSKillSwitch = True
#else
_isAWSKillSwitch :: Bool
_isAWSKillSwitch = False
#endif

_killSwitchNodeCheck :: Config -> IO ()
_killSwitchNodeCheck rconf = do
  let beta_node_limit = 16
  let aws_node_limit = 4
  let currNodeCount = (CM.countOthers (_clusterMembers rconf)) -- doesn't include node executing this code

  let betaSwitch = _isBetaKillSwitch
  let awsSwitch = _isAWSKillSwitch

  case (betaSwitch,awsSwitch) of
    (False, False) -> return ()
    (True,  False) -> when (currNodeCount >= beta_node_limit) $
                      error $ "Beta versions of Kadena are limited to 16 consensus nodes."
    (False, True)  -> when (currNodeCount >= aws_node_limit) $
                      error $ "Community versions of Kadena are limited to 4 consensus nodes."
    (True,  True)  -> when (currNodeCount >= beta_node_limit) $
                      error $ "Community versions of Kadena are limited to 4 consensus nodes."
                      -- Apply strictess kill-switch limitations (i.e. the Beta kill switch)
