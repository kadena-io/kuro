{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Config.Pact.Types
  ( PactPersistBackend(..)
  , PactPersistConfig(..)
  , PPBType(..) ) where

import Data.Aeson
import qualified Data.Aeson as A
import GHC.Generics

import Pact.Persist.MSSQL (MSSQLConfig(..))
import Pact.Types.Util
import Pact.Types.SQLite (SQLiteConfig)

data PactPersistBackend =
    PPBInMemory |
    PPBSQLite { _ppbSqliteConfig :: SQLiteConfig } |
    PPBMSSQL { _ppbMssqlConfig :: Maybe MSSQLConfig,
               _ppbMssqlConnStr :: String }
    deriving (Show,Generic)

data PactPersistConfig = PactPersistConfig {
  _ppcWriteBehind :: Bool,
  _ppcBackend :: PactPersistBackend
  } deriving (Show,Generic)
instance ToJSON PactPersistConfig where toJSON = lensyToJSON 4
instance FromJSON PactPersistConfig where parseJSON = lensyParseJSON 4

data PPBType = SQLITE|MSSQL|INMEM deriving (Eq,Show,Read,Generic,FromJSON,ToJSON)

instance FromJSON PactPersistBackend where
  parseJSON = A.withObject "PactPersistBackend" $ \o -> do
    ty <- o .: "type"
    case ty of
      SQLITE -> PPBSQLite <$> o .: "config"
      MSSQL -> PPBMSSQL <$> o .:? "config" <*> o .: "connStr"
      INMEM -> return PPBInMemory
instance ToJSON PactPersistBackend where
  toJSON p = A.object $ case p of
    PPBInMemory -> [ "type" .= INMEM ]
    PPBSQLite {..} -> [ "type" .= SQLITE, "config" .= _ppbSqliteConfig ]
    PPBMSSQL {..} -> [ "type" .= MSSQL, "config" .= _ppbMssqlConfig, "connStr" .= _ppbMssqlConnStr ]
