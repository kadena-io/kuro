{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Juno.Spec.TestRig
  ( mkTestConfig
  , testJuno
  ) where

import Control.Arrow
import Control.AutoUpdate (mkAutoUpdate, defaultUpdateSettings,updateAction,updateFreq)
import Control.Concurrent (modifyMVar_, MVar, newEmptyMVar)
import qualified Control.Concurrent.Chan.Unagi as Unagi
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class

import Crypto.Random
import Crypto.Ed25519.Pure

import Data.Monoid ((<>))
import Data.Ratio
import Data.Thyme.Calendar (showGregorian)
import Data.Thyme.LocalTime
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Set as Set
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Data.Thyme.Clock

import System.Log.FastLogger
import System.Random

import Juno.Consensus.Server
import Juno.Types hiding (timeCache)
import Juno.Messaging.ZMQ
import qualified Juno.Runtime.MessageReceiver as RENV

nodes :: [NodeId]
nodes = iterate (\n@(NodeId h p _ _) -> n {_port = p + 1
                                          , _fullAddr = "tcp://" ++ h ++ ":" ++ show (p+1)
                                          , _alias = Alias $ BSC.pack $ "node" ++ show (p+1-10000)})
                    (NodeId "127.0.0.1" 10000 "tcp://127.0.0.1:10000" $ Alias "node0")

makeKeys :: CryptoRandomGen g => Int -> g -> [(PrivateKey,PublicKey)]
makeKeys 0 _ = []
makeKeys n g = case generateKeyPair g of
  Left err -> error $ show err
  Right (p,priv,g') -> (p,priv) : makeKeys (n-1) g'

keyMaps :: [(PrivateKey,PublicKey)] -> (Map NodeId PrivateKey, Map NodeId PublicKey)
keyMaps ls = (Map.fromList $ zip nodes (fst <$> ls), Map.fromList $ zip nodes (snd <$> ls))


-- | Creates a (ClusterConfig, ClientConfig) configured to a specific cluster size
mkTestConfig :: Int -> IO (Config, Config, (Map NodeId PrivateKey, Map NodeId PublicKey))
mkTestConfig clusterSize' = do
  g <- newGenIO :: IO SystemRandom
  keyMaps' <- return $! keyMaps $ makeKeys (clusterSize' + 1) g
  clientIds <- return $ take 1 $ drop clusterSize' nodes
  let isAClient nid _ = Set.member nid (Set.fromList clientIds)
  let isNotAClient nid _ = not $ Set.member nid (Set.fromList clientIds)
  clusterKeyMaps <- return $ (Map.filterWithKey isNotAClient *** Map.filterWithKey isNotAClient) keyMaps'
  clientKeyMaps <- return $ (Map.filterWithKey isAClient *** Map.filterWithKey isAClient) keyMaps'
  return $ ( head $ (createClusterConfig clusterKeyMaps (snd clientKeyMaps) <$> take clusterSize' nodes)
           , head $ (createClientConfig (snd clusterKeyMaps) clientKeyMaps <$> clientIds)
           , clusterKeyMaps)

createClusterConfig :: (Map NodeId PrivateKey, Map NodeId PublicKey) -> Map NodeId PublicKey -> NodeId -> Config
createClusterConfig (privMap, pubMap) clientPubMap nid = Config
  { _otherNodes           = Set.delete nid $ Map.keysSet pubMap
  , _nodeId               = nid
  , _publicKeys           = pubMap
  , _clientPublicKeys     = Map.union pubMap clientPubMap -- NOTE: [2016 04 26] all nodes are client (support API signing)
  , _myPrivateKey         = privMap Map.! nid
  , _myPublicKey          = pubMap Map.! nid
  , _myEncryptionKey      = EncryptionKey $ exportPublic $ pubMap Map.! nid
  , _electionTimeoutRange = (3000000,6000000)
  , _heartbeatTimeout     = 1000000              -- seems like a while...
  , _batchTimeDelta       = fromSeconds' (1%100) -- default to 10ms
  , _enableDebug          = True
  , _clientTimeoutLimit   = 50000
  , _dontDebugFollower    = False
  , _apiPort              = 8000
  , _logSqlitePath        = ""
  , _enableAwsIntegration = False
  }

createClientConfig :: Map NodeId PublicKey -> (Map NodeId PrivateKey, Map NodeId PublicKey) -> NodeId -> Config
createClientConfig clusterPubMap (privMap, pubMap) nid = Config
  { _otherNodes           = Map.keysSet clusterPubMap
  , _nodeId               = nid
  , _publicKeys           = clusterPubMap
  , _clientPublicKeys     = pubMap
  , _myPrivateKey         = privMap Map.! nid
  , _myPublicKey          = pubMap Map.! nid
  , _myEncryptionKey      = EncryptionKey $ exportPublic $ pubMap Map.! nid
  , _electionTimeoutRange = (3000000,6000000)
  , _heartbeatTimeout     = 1000000
  , _batchTimeDelta       = fromSeconds' (1%100) -- default to 10ms
  , _enableDebug          = False
  , _clientTimeoutLimit   = 50000
  , _dontDebugFollower    = False
  , _apiPort              = 8000
  , _logSqlitePath        = ""
  , _enableAwsIntegration = False
  }

showDebug :: TimedFastLogger -> String -> IO ()
showDebug fs m = fs (\t -> (toLogStr t) <> " " <> (toLogStr $ BSC.pack $ m) <> "\n")

noDebug :: String -> IO ()
noDebug _ = return ()

getSysLogTime :: IO (FormattedTime)
getSysLogTime = do
  (ZonedTime (LocalTime d t) _) <- getZonedTime
  return $ BSC.pack $ (showGregorian d) ++ "T" ++ (take 12 $ show t)


timeCache :: TimeZone -> (IO UTCTime) -> IO (IO FormattedTime)
timeCache tz tc = mkAutoUpdate defaultUpdateSettings
  { updateAction = do
      t' <- tc
      (ZonedTime (LocalTime d t) _) <- return $ view (zonedTime) (tz,t')
      return $ BSC.pack $ (showGregorian d) ++ "T" ++ (take 12 $ show t)
  , updateFreq = 1000}


utcTimeCache :: IO (IO UTCTime)
utcTimeCache = mkAutoUpdate defaultUpdateSettings
  { updateAction = getCurrentTime
  , updateFreq = 1000}

initSysLog :: (IO UTCTime) -> IO (TimedFastLogger)
initSysLog tc = do
  tz <- getCurrentTimeZone
  fst <$> newTimedFastLogger (join $ timeCache tz tc) (LogStdout defaultBufSize)

simpleRaftSpec :: (Command -> IO CommandResult)
               -> (String -> IO ())
               -> (MVar CommandMap -> RequestId -> CommandStatus -> IO ())
               -> CommandMVarMap
               -> Unagi.OutChan (RequestId, [(Maybe Alias, CommandEntry)]) --IO (RequestId, [CommandEntry])
               -> RaftSpec
simpleRaftSpec applyFn debugFn updateMapFn cmdMVarMap getCommands = RaftSpec
    {
      -- apply log entries to the state machine, given by caller
      _applyLogEntry   = applyFn
      -- use the debug function given by the caller
    , _debugPrint      = debugFn
      -- publish a 'Metric' to EKG
    , _publishMetric   = \_ -> return ()
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


testJuno :: Config -> RaftState -> Dispatch -> (Command -> IO CommandResult) -> IO ()
testJuno rconf rstate dispatch applyFn = do
  sharedCmdStatusMap <- initCommandMap
  me <- return $ rconf ^. nodeId
  oNodes <- return $ Set.toList $ Set.delete me $ Set.union (rconf ^. otherNodes) (Map.keysSet $ rconf ^. clientPublicKeys)

  (_emptyAPIChanIn,emptyAPIChanOut) <- Unagi.newChan

  utcTimeCache' <- utcTimeCache
  fs <- initSysLog utcTimeCache'
  let debugFn = if (rconf ^. enableDebug) then showDebug fs else noDebug

  -- each node has its own snap monitoring server

  -- EMPTY ME --
  runMsgServer dispatch me oNodes debugFn -- ZMQ
  let raftSpec = simpleRaftSpec
                   (liftIO . applyFn)
                   (debugFn)
                   updateCmdMapFn
                   sharedCmdStatusMap
                   emptyAPIChanOut
  restartTurbo <- newEmptyMVar
  let receiverEnv = simpleReceiverEnv dispatch rconf debugFn restartTurbo
  runPrimedRaftServer receiverEnv rconf raftSpec rstate utcTimeCache'
