{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.ConfigChange.Service 
  ( diffNodes
  , execConfigUpdateCmd  
  , mutateConfig  
  , processConfigUpdate    
  , runConfigChangeService
  , runConfigUpdater
  , updateNodeMap
  , updateNodeSet
  ) where
 
import Control.Concurrent.STM    
import Data.Aeson    
import Data.ByteString (ByteString)  
import Data.Map (Map)
import qualified Data.Map as Map 
import Data.Set (Set)
import qualified Data.Set as Set
import Kadena.ConfigChange.Types
import Kadena.Types.Base
import Kadena.Types.Config

runConfigChangeService :: ConfigChangeService ConfigChangeState ()
runConfigChangeService = do 
    return () 

processConfigUpdate :: ConfigUpdate ByteString -> ProcessedConfigUpdate
processConfigUpdate ConfigUpdate{..} =
  let
    hash' = hash _cuCmd
    sigs = (\(k,s) -> (valid hash' k s,k,s)) <$> Map.toList _cuSigs
    sigsValid :: Bool
    sigsValid = all (\(v,_,_) -> v) sigs
    invalidSigs = filter (\(v,_,_) -> not v) sigs
  in if hash' /= _cuHash
     then ProcessedConfigFailure $! "Hash Mismatch in ConfigUpdate: ours=" ++ show hash' ++ " theirs=" ++ show _cuHash
     else if sigsValid
          then case eitherDecodeStrict' _cuCmd of
                 Left !err -> ProcessedConfigFailure err
                 Right !v -> ProcessedConfigSuccess v (Map.keysSet _cuSigs)
          else ProcessedConfigFailure $! "Sig(s) Invalid: " ++ show invalidSigs
{-# INLINE processConfigUpdate #-}

execConfigUpdateCmd :: Config -> ConfigUpdateCommand -> IO (Either String Config)
execConfigUpdateCmd conf@Config{..} cuc = do
  case cuc of
    AddNode{..}
      | _nodeId == _cucNodeId || Set.member _cucNodeId _otherNodes ->
          return $ Left $ "Unable to add node, already present"
      | _cucNodeClass == Passive ->
          return $ Left $ "Passive mode is not currently supported"
      | otherwise ->
          return $ Right $! conf
          { _otherNodes = Set.insert _cucNodeId _otherNodes
          , _publicKeys = Map.insert (_alias _cucNodeId) _cucPublicKey _publicKeys }
    RemoveNode{..}
      | _nodeId == _cucNodeId || Set.member _cucNodeId _otherNodes ->
          return $ Right $! conf
            { _otherNodes = Set.delete _cucNodeId _otherNodes
            , _publicKeys = Map.delete (_alias _cucNodeId) _publicKeys }
      | otherwise ->
          return $ Left $ "Unable to delete node, not found"
    NodeToPassive{..} -> return $ Left $ "Passive mode is not currently supported"
    NodeToActive{..} -> return $ Left $ "Active mode is the only mode currently supported"
    UpdateNodeKey{..}
      | _alias _nodeId == _cucAlias -> do
          KeyPair{..} <- getNewKeyPair _cucKeyPairPath
          return $ Right $! conf
            { _myPublicKey = _kpPublicKey
            , _myPrivateKey = _kpPrivateKey }
      | Map.member _cucAlias _publicKeys -> return $ Right $! conf
          { _publicKeys = Map.insert _cucAlias _cucPublicKey _publicKeys }
      | otherwise -> return $ Left $ "Unable to delete node, not found"
    AddAdminKey{..}
      | Map.member _cucAlias _adminKeys ->
          return $ Left $ "admin alias already present: " ++ show _cucAlias
      | otherwise -> return $ Right $! conf
          { _adminKeys = Map.insert _cucAlias _cucPublicKey _adminKeys }
    UpdateAdminKey{..}
      | Map.member _cucAlias _adminKeys -> return $ Right $! conf
          { _adminKeys = Map.insert _cucAlias _cucPublicKey _adminKeys }
      | otherwise ->
          return $ Left $ "Unable to find admin alias: " ++ show _cucAlias
    RemoveAdminKey{..}
      | Map.member _cucAlias _adminKeys -> return $ Right $! conf
          { _adminKeys = Map.delete _cucAlias _adminKeys }
      | otherwise ->
          return $ Left $ "Unable to find admin alias: " ++ show _cucAlias
    RotateLeader{..} ->
      return $ Left $ "Admin triggered leader rotation is not currently supported"

mutateConfig :: GlobalConfigTMVar -> ProcessedConfigUpdate -> IO ConfigUpdateResult
mutateConfig _ (ProcessedConfigFailure err) = return $ ConfigUpdateFailure err
mutateConfig gc (ProcessedConfigSuccess cuc keysUsed) = do
  origGc@GlobalConfig{..} <- atomically $ takeTMVar gc
  missingKeys <- return $ getMissingKeys _gcConfig keysUsed
  if null missingKeys
  then do
    res <- execConfigUpdateCmd _gcConfig cuc
    case res of
      Left err -> return $! ConfigUpdateFailure $ "Failure: " ++ err
      Right conf' -> atomically $ do
        putTMVar gc $ GlobalConfig { _gcVersion = ConfigVersion $ configVersion _gcVersion + 1
                                  , _gcConfig = conf' }
        return ConfigUpdateSuccess
  else do
    atomically $ putTMVar gc origGc
    return $ ConfigUpdateFailure $ "Admin signatures missing from: " ++ show missingKeys
  
runConfigUpdater :: ConfigUpdater -> GlobalConfigTMVar -> IO ()
runConfigUpdater ConfigUpdater{..} gcm = go initialConfigVersion
  where
    go cv = do
      GlobalConfig{..} <- atomically $ getConfigWhenNew cv gcm
      _cuAction _gcConfig
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

diffNodes :: NodesToDiff -> DiffNodes
diffNodes NodesToDiff{..} = DiffNodes
  { nodesToAdd = Set.difference currentNodes prevNodes
  , nodesToRemove = Set.difference prevNodes currentNodes }    