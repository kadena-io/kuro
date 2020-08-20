{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Kadena.Types.PactDB
  ( PactPersistBackend(..)
  , PactPersistConfig(..)
  , PPBType(..) ) where

#ifdef DB_ADAPTERS
import Control.Applicative
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
#endif
import Data.Aeson
import qualified Data.Aeson as A
import GHC.Generics

#ifdef DB_ADAPTERS
import Pact.Persist.MSSQL (MSSQLConfig(..))
#endif
import Pact.Types.Util
import Pact.Types.SQLite (SQLiteConfig)

data PactPersistBackend =
    PPBInMemory
    |
    PPBSQLite { _ppbSqliteConfig :: SQLiteConfig }
#ifdef DB_ADAPTERS
    |
    PPBMSSQL { _ppbMssqlConfig :: Maybe MSSQLConfig,
               _ppbMssqlConnStr :: String }
    |
    PPBMySQL { _ppbMysqlConfig :: ConnectInfo}
#endif
    deriving (Show,Generic)

data PactPersistConfig = PactPersistConfig {
  _ppcWriteBehind :: Bool,
  _ppcBackend :: PactPersistBackend
  } deriving (Show,Generic)
instance ToJSON PactPersistConfig where toJSON = lensyToJSON 4
instance FromJSON PactPersistConfig where parseJSON = lensyParseJSON 4

data PPBType =
  INMEM
  |
  SQLITE
#ifdef DB_ADAPTERS
  |
  MYSQL
  |
  MSSQL
#endif
  deriving (Eq,Show,Read,Generic,FromJSON,ToJSON)

instance FromJSON PactPersistBackend where
  parseJSON = A.withObject "PactPersistBackend" $ \o -> do
    ty <- o .: "type"
    case ty of
      SQLITE -> PPBSQLite <$> o .: "config"
      INMEM -> return PPBInMemory
#ifdef DB_ADAPTERS
      MSSQL -> PPBMSSQL <$> o .:? "config" <*> o .: "connStr"
      MYSQL -> PPBMySQL <$> o .: "config"
#endif
instance ToJSON PactPersistBackend where
  toJSON p = A.object $ case p of
    PPBInMemory -> [ "type" .= INMEM ]
    PPBSQLite {..} -> [ "type" .= SQLITE, "config" .= _ppbSqliteConfig ]
#ifdef DB_ADAPTERS
    PPBMSSQL {..} -> [ "type" .= MSSQL, "config" .= _ppbMssqlConfig, "connStr" .= _ppbMssqlConnStr ]
    PPBMySQL {..} -> [ "type" .= MYSQL, "config" .= _ppbMysqlConfig ]
#endif

#ifdef DB_ADAPTERS
-- Orphan instances for ConnectInfo
instance ToJSON ConnectInfo where
  toJSON ConnectInfo{..} = object
    ["host" .= connectHost, "port" .= connectPort, "user" .= connectUser,
     "password" .= connectPassword, "database" .= connectDatabase,
     "options" .= connectOptions, "path" .= connectPath, "ssl" .= connectSSL]
instance FromJSON ConnectInfo where
  parseJSON =
    withObject "ConnectInfo" $ \o ->
      ConnectInfo <$> o .: "host" <*> o .: "port" <*> o .: "user" <*> o .: "password"
      <*> o .: "database" <*> o .: "options" <*> o .: "path" <*> o .: "ssl"

instance ToJSON Option where
  toJSON (ConnectTimeout s) = object ["connectTimeout" .= s]
  toJSON Compress = "Compress"
  toJSON NamedPipe = "NamedPipe"
  toJSON (InitCommand b) = object ["initCommand" .= decodeUtf8 b]
  toJSON (ReadDefaultFile fp) = object ["readDefaultFile" .= fp]
  toJSON (ReadDefaultGroup b) = object ["readDefaultGroup" .= decodeUtf8 b]
  toJSON (CharsetDir fp) = object ["charsetDir" .= fp]
  toJSON (CharsetName s) = object ["charsetName" .= s]
  toJSON (LocalInFile o) = object ["localInFile" .= o]
  toJSON (Protocol p) = object ["protocol" .= p]
  toJSON (SharedMemoryBaseName b) = object ["sharedMemoryBaseName" .= decodeUtf8 b]
  toJSON (ReadTimeout s) = object ["readTimeout" .= s]
  toJSON (WriteTimeout s) = object ["writeTimeout" .= s]
  toJSON UseRemoteConnection = "UseRemoteConnection"
  toJSON UseEmbeddedConnection = "UseEmbeddedConnection"
  toJSON GuessConnection = "GuessConnection"
  toJSON (ClientIP b) = object ["clientIP" .= decodeUtf8 b]
  toJSON (SecureAuth o) = object ["secureAuth" .= o]
  toJSON (ReportDataTruncation o) = object ["reportDataTruncation" .= o]
  toJSON (Reconnect o) = object ["reconnect" .= o]
  toJSON (SSLVerifyServerCert o) = object ["sslVerifyServerCert" .= o]
  toJSON FoundRows = "FoundRows"
  toJSON IgnoreSIGPIPE = "IgnoreSIGPIPE"
  toJSON IgnoreSpace = "IgnoreSpace"
  toJSON Interactive = "Interactive"
  toJSON LocalFiles = "LocalFiles"
  toJSON MultiResults = "MultiResults"
  toJSON MultiStatements = "MultiStatements"
  toJSON NoSchema = "NoSchema"
instance FromJSON Option where
  parseJSON v = case v of
    Object _ -> withObject "Option" objectParser v
    String _ -> withText "Options" stringParser v
    _ -> fail "Invalid Option value"
    where objectParser o =
            (ConnectTimeout <$> o .: "connectTimeout") <|>
            ((InitCommand . encodeUtf8) <$> o .: "initCommand") <|>
            (ReadDefaultFile <$> o .: "readDefaultFile") <|>
            ((ReadDefaultGroup . encodeUtf8) <$> o .: "readDefaultGroup") <|>
            (CharsetDir <$> o .: "charsetDir") <|>
            (CharsetName <$> o .: "charsetName") <|>
            (LocalInFile <$> o .: "localInFile") <|>
            (Protocol <$> o .: "protocol") <|>
            ((SharedMemoryBaseName . encodeUtf8) <$> o .: "sharedMemoryBaseName") <|>
            (ReadTimeout <$> o .: "readTimeout") <|>
            (WriteTimeout <$> o .: "writeTimeout") <|>
            ((ClientIP . encodeUtf8) <$> o .: "clientIP") <|>
            (SecureAuth <$> o .: "secureAuth") <|>
            (ReportDataTruncation <$> o .: "reportDataTruncation") <|>
            (Reconnect <$> o .: "reconnect") <|>
            (SSLVerifyServerCert <$> o .: "sslVerifyServerCert")
          stringParser s = case s of
            "Compress" -> return Compress
            "NamedPipe" -> return NamedPipe
            "UseRemoteConnection" -> return UseRemoteConnection
            "UseEmbeddedConnection" -> return UseEmbeddedConnection
            "GuessConnection" -> return GuessConnection
            "FoundRows" -> return FoundRows
            "IgnoreSIGPIPE" -> return IgnoreSIGPIPE
            "IgnoreSpace" -> return IgnoreSpace
            "Interactive" -> return Interactive
            "LocalFiles" -> return LocalFiles
            "MultiResults" -> return MultiResults
            "MultiStatements" -> return MultiStatements
            "NoSchema" -> return NoSchema
            _ -> fail "Invalid Option value"

instance ToJSON Protocol where
  toJSON TCP = "TCP"
  toJSON Socket = "Socket"
  toJSON Pipe = "Pipe"
  toJSON Memory = "Memory"
instance FromJSON Protocol where
  parseJSON =
    withText "Protocol" $ \o ->
      case o of
        "TCP" -> return TCP
        "Socket" -> return Socket
        "Pipe" -> return Pipe
        "Memory" -> return Memory
        _ -> fail "Invalid Protocol value"

instance ToJSON SSLInfo where
  toJSON SSLInfo{..} = A.object ["key" .= sslKey, "cert" .= sslCert,
                                 "CA" .= sslCA, "CAPath" .= sslCAPath,
                                 "ciphers" .= sslCiphers]
instance FromJSON SSLInfo where
  parseJSON = A.withObject "SSLInfo" $ \o ->
    SSLInfo <$> o .: "key" <*> o .: "cert" <*> o .: "CA" <*> o .: "CAPath" <*> o .: "ciphers"
#endif
