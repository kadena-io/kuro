{-# LANGUAGE RecordWildCards #-}

module Kadena.ConfigChange.Service
  ( diffNodes
  , execClusterChangeCmd
  , mutateCluster
  , runConfigChangeService
  , runConfigUpdater
  , updateNodeMap
  , updateNodeSet
  ) where

import Control.Concurrent.STM
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.RWS.Lazy
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Kadena.ConfigChange.Types
import Kadena.Event
import Kadena.Types.Base
import Kadena.Types.Comms
import Kadena.Types.Config
import Kadena.Types.Dispatch (Dispatch)
import qualified Kadena.Types.Dispatch as D
import Kadena.Types.Metric

runConfigChangeService :: Dispatch
                       -> (String -> IO())
                       -> (Metric -> IO())
                       -> Config
                       -> IO ()
runConfigChangeService dispatch dbg publishMetric' rconf =
  let env = ConfigChangeEnv
        { _cfgChangeChannel = dispatch ^. D.cfgChangeChannel
        , _debugPrint = dbg
        , _publishMetric = publishMetric'
        , _config = rconf
        }
      initCfgChangeState' = ConfigChangeState
        { _cssTbd = 0
        }
  in void $ runRWST handle  env initCfgChangeState'

handle :: ConfigChangeService ()
handle = do
  newChg <- view cfgChangeChannel >>= liftIO . readComm
  case newChg of
    CfgChange ConfigChange{..} -> do
      --MLN: TBD - add restart code here
      -- let newNodes = newNodeSet
      -- let consenLists = consensusLists
      -- TBD...
      debug "[Kadena.ConfigChange.Service]: **** TBD: Restart Now *****"
      liftIO $ putStrLn "TBD: Restart Now"
    Heart t -> do
      liftIO (pprintBeat t) >>= debug
      handle

debug :: String -> ConfigChangeService ()
debug s = do
  dbg <- view debugPrint
  liftIO $! dbg $! "[Kadena.ConfigChange.Service]: " ++ s

mutateCluster :: GlobalConfigTMVar -> ProcessedClusterChg -> IO ClusterChangeResult
mutateCluster _ (ProcClusterChgFail err) = return $ ClusterChangeFailure err
mutateCluster gc (ProcClusterChgSucc cmd) = do
  origGc@GlobalConfig{..} <- atomically $ takeTMVar gc
  missingKeys <- return $ getMissingKeys _gcConfig (_cccSigs cmd)
  if null missingKeys
  then do
    conf' <- execClusterChangeCmd _gcConfig cmd
    atomically $ do
        putTMVar gc $ GlobalConfig { _gcVersion = ConfigVersion $ configVersion _gcVersion + 1
                                   , _gcConfig = conf' }
        return ClusterChangeSuccess
  else do
    atomically $ putTMVar gc origGc
    return $ ClusterChangeFailure $ "Admin signatures missing from: " ++ show missingKeys

execClusterChangeCmd :: Config -> ClusterChangeCommand -> IO Config
execClusterChangeCmd cfg ccc = do
  let changeInfo = _cccPayload ccc
  case _cciState changeInfo of
    Transitional -> return $ cfg { _changeToNodes = Set.fromList $ _cciNewNodeList changeInfo }
    Final -> do
      let others = Set.fromList $ _cciNewNodeList changeInfo
      -- remove the current node from the new list of "otherNodes" (it may also
      -- not be in the new configuration at all, in which case delete does nothing)
      let others' = Set.delete (_nodeId cfg) others
      return cfg { _otherNodes = others'
                 , _changeToNodes = Set.empty
                 }

runConfigUpdater :: ConfigUpdater -> GlobalConfigTMVar -> IO ()
runConfigUpdater ConfigUpdater{..} gcm = go initialConfigVersion
  where
    go cv = do
      GlobalConfig{..} <- atomically $ getConfigWhenNew cv gcm
      _cuAction _gcConfig --  --call the update 'action' function
      _cuPrintFn $ "[" ++ _cuThreadName ++ "] config update fired for version: " ++ show _gcVersion
      go _gcVersion

updateNodeMap :: DiffNodes -> Map NodeId a -> (NodeId -> a) -> Map NodeId a
updateNodeMap DiffNodes{..} m defaultVal =
  let
    removedNodes = Map.filterWithKey (\k _ -> Set.notMember k nodesToRemove) m
  in Map.union removedNodes $ Map.fromSet defaultVal nodesToAdd

updateNodeSet :: DiffNodes -> Set NodeId -> Set NodeId
updateNodeSet DiffNodes{..} s =
  let removedNodes = Set.filter (`Set.notMember` nodesToRemove) s
  in Set.union removedNodes nodesToAdd

diffNodes :: Set NodeId -> Set NodeId -> DiffNodes
diffNodes prevNodes newNodes = DiffNodes
  { nodesToAdd = Set.difference newNodes prevNodes
  , nodesToRemove = Set.difference prevNodes newNodes }