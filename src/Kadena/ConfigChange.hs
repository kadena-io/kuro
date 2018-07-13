{-# LANGUAGE RecordWildCards #-}

module Kadena.ConfigChange
  ( diffNodes
  , execClusterChangeCmd
  , mkConfigChangeApiReq
  , mutateGlobalConfig
  , runConfigUpdater
  , updateNodeMap
  , updateNodeSet
  ) where

import Control.Concurrent.STM
import Control.Monad.IO.Class
import Control.Monad.Catch hiding (handle)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Yaml as Y
import Kadena.Config.ClusterMembership
import Kadena.Config.TMVar
import Kadena.ConfigChange.Util
import Kadena.Types.Base
import Kadena.Types.Command
import Kadena.Types.Config
import Kadena.Config

mutateGlobalConfig :: GlobalConfigTMVar -> ProcessedClusterChg CCPayload -> IO ClusterChangeResult
mutateGlobalConfig _ (ProcClusterChgFail err) = return $ ClusterChangeFailure err
mutateGlobalConfig gc (ProcClusterChgSucc cmd) = do
  origGc@GlobalConfig{..} <- atomically $ takeTMVar gc
  missingKeys <- getMissingKeys _gcConfig (_cccSigs cmd)
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

execClusterChangeCmd :: Config -> ClusterChangeCommand CCPayload -> IO Config
execClusterChangeCmd cfg ClusterChangeCommand{..} = do
  let changeInfo = _ccpInfo _cccPayload
  let theMembers = _clusterMembers cfg
  let newMembers = case _cciState changeInfo of
        Transitional -> setTransitional theMembers (Set.fromList $ _cciNewNodeList changeInfo)
        Final -> do
          let others = Set.fromList $ _cciNewNodeList changeInfo
          -- remove the current node from the new list of "other nodes" (it may also
          -- not be in the new configuration at all, in which case delete does nothing)
          let others' = Set.delete (_nodeId cfg) others
          mkClusterMembership others' Set.empty
  return cfg { _clusterMembers = newMembers}

runConfigUpdater :: ConfigUpdater -> GlobalConfigTMVar -> IO ()
runConfigUpdater ConfigUpdater{..} gcm = go initialConfigVersion
  where
    go cv = do
      GlobalConfig{..} <- atomically $ getConfigWhenNew cv gcm
      -- error "runConfigUpdater -- global config change detected"
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

mkConfigChangeApiReq :: FilePath -> IO ConfigChangeApiReq
mkConfigChangeApiReq fp =
  either (yamlErr . show) return =<< liftIO (Y.decodeFileEither fp)

yamlErr :: String -> IO a
yamlErr errMsg = throwM  . userError $ "Failure reading yaml: " ++ errMsg
