{-# LANGUAGE RecordWildCards #-}

module Kadena.Config
  ( confToKeySet
  , getConfigWhenNew
  , getNewKeyPair
 ) where

import Control.Concurrent.STM
import qualified Data.Yaml as Y

import Kadena.Crypto
import Kadena.Config.TMVar
import Kadena.Types.Base

getConfigWhenNew :: ConfigVersion -> GlobalConfigTMVar -> STM GlobalConfig
getConfigWhenNew cv gcm = do
  gc@GlobalConfig{..} <- readTMVar gcm
  if _gcVersion > cv
  then return gc
  else retry

getNewKeyPair :: FilePath -> IO KeyPair
getNewKeyPair fp = do
  kp <- Y.decodeFileEither fp
  case kp of
    Left err -> error $ "Unable to find and decode new keypair at location: " ++ fp ++ "\n## Error ##\n" ++ show err
    Right kp' -> return kp'

confToKeySet :: Config -> KeySet
confToKeySet Config{..} = KeySet
  { _ksCluster = _publicKeys}
