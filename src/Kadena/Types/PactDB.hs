{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Types.PactDB
  ( PactPersistBackend(..)
  , PactPersistConfig(..)
  , PPBType(..) ) where

import Database.MySQL.Base (ConnectInfo(..), Option(..), SSLInfo(..), Protocol(..))
import Data.Aeson
import qualified Data.Aeson as A
import qualified Data.ByteString as B (ByteString)
import GHC.Generics

import Pact.Persist.MSSQL (MSSQLConfig(..))
import Pact.Types.Util
import Pact.Types.SQLite (SQLiteConfig)

data PactPersistBackend =
    PPBInMemory |
    PPBSQLite { _ppbSqliteConfig :: SQLiteConfig } |
    PPBMSSQL { _ppbMssqlConfig :: Maybe MSSQLConfig,
               _ppbMssqlConnStr :: String } |
    PPBMySQL { _ppbMysqlConfig :: ConnectInfo}
    deriving (Show,Generic)

data PactPersistConfig = PactPersistConfig {
  _ppcWriteBehind :: Bool,
  _ppcBackend :: PactPersistBackend
  } deriving (Show,Generic)
instance ToJSON PactPersistConfig where toJSON = lensyToJSON 4
instance FromJSON PactPersistConfig where parseJSON = lensyParseJSON 4

data PPBType = MYSQL|SQLITE|MSSQL|INMEM deriving (Eq,Show,Read,Generic,FromJSON,ToJSON)

instance FromJSON PactPersistBackend where
  parseJSON = A.withObject "PactPersistBackend" $ \o -> do
    ty <- o .: "type"
    case ty of
      SQLITE -> PPBSQLite <$> o .: "config"
      MSSQL -> PPBMSSQL <$> o .:? "config" <*> o .: "connStr"
      MYSQL -> PPBMySQL <$> o .: "config"
      INMEM -> return PPBInMemory
instance ToJSON PactPersistBackend where
  toJSON p = A.object $ case p of
    PPBInMemory -> [ "type" .= INMEM ]
    PPBSQLite {..} -> [ "type" .= SQLITE, "config" .= _ppbSqliteConfig ]
    PPBMSSQL {..} -> [ "type" .= MSSQL, "config" .= _ppbMssqlConfig, "connStr" .= _ppbMssqlConnStr ]
    PPBMySQL {..} -> [ "type" .= MYSQL, "config" .= _ppbMysqlConfig ]

-- Orphan instances for ConnectInfo
deriving instance Generic ConnectInfo
deriving instance Generic Option
deriving instance Generic SSLInfo
deriving instance Generic Protocol

instance ToJSON B.ByteString where toJSON = toB16JSON
instance FromJSON B.ByteString where parseJSON = parseB16JSON

instance ToJSON Protocol where toJSON = lensyToJSON 4
instance FromJSON Protocol where parseJSON = lensyParseJSON 4

instance ToJSON SSLInfo where toJSON = lensyToJSON 4
instance FromJSON SSLInfo where parseJSON = lensyParseJSON 4

instance ToJSON Option where toJSON = lensyToJSON 4
instance FromJSON Option where parseJSON = lensyParseJSON 4

instance ToJSON ConnectInfo where toJSON = lensyToJSON 4
instance FromJSON ConnectInfo where parseJSON = lensyParseJSON 4
