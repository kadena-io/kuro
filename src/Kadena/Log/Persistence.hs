{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Kadena.Log.Persistence
  ( createDB
  , insertSeqLogEntry
  , selectAllLogEntries
  , selectAllLogEntriesAfter
  , selectLastLogEntry
  , selectLogEntriesInclusiveSection
  , selectSpecificLogEntry
  ) where

import Data.Typeable
import Data.Set (Set)
import qualified Data.Map.Strict as Map
import Data.Serialize
import Data.ByteString hiding (concat, length, head, null)
import qualified Data.Text as T

import Database.SQLite.Simple
import Database.SQLite.Simple.Ok
import Database.SQLite.Simple.ToField
import Database.SQLite.Simple.FromField

import qualified Data.Aeson as Aeson

import Kadena.Types

-- These live here as orphans, and not in Types, because trying to Serialize these things should be a type level error
-- with rare exception (i.e. for hashing the log entry). Moreover, accidentally sending Provenance over the wire could
-- be hard to catch. Best to make it impossible.
instance Serialize Command
instance Serialize Provenance
instance Serialize LogEntry
instance Serialize RequestVoteResponse

instance ToField NodeId where
  toField n = toField $ Aeson.encode n
instance FromField NodeId where
  fromField f = do
    s :: ByteString <- fromField f
    case Aeson.eitherDecodeStrict s of
      Left err -> returnError ConversionFailed f ("Couldn't deserialize NodeId: " ++ err)
      Right n -> Ok n

instance ToField LogIndex where
  toField (LogIndex i) = toField i
instance FromField LogIndex where
  fromField a = LogIndex <$> fromField a

instance ToField Term where
  toField (Term a) = toField a
instance FromField Term where
  fromField a = Term <$> fromField a

instance (Aeson.ToJSON a, Ord a, Serialize a) => ToField (Set a) where
  toField s = toField $ Aeson.encode s
instance (Aeson.FromJSON a, Ord a, Typeable a, Serialize a) => FromField (Set a) where
  fromField f = do
    s :: ByteString <- fromField f
    case Aeson.eitherDecodeStrict s of
      Left err -> returnError ConversionFailed f ("Couldn't deserialize Set: " ++ err)
      Right v -> Ok v

instance ToField Provenance where
  toField = toField . encode
instance FromField Provenance where
  fromField f = do
    s :: ByteString <- fromField f
    case decode s of
      Left err -> returnError ConversionFailed f ("Couldn't deserialize Provenance: " ++ err)
      Right v -> Ok v

instance ToField CommandEntry where
  toField (CommandEntry e) = toField e
instance FromField CommandEntry where
  fromField f = CommandEntry <$> fromField f

instance ToField RequestId where
  toField (RequestId rid) = toField rid
instance FromField RequestId where
  fromField f = RequestId <$> fromField f

instance ToField Alias where
  toField (Alias a) = toField a
instance FromField Alias where
  fromField f = Alias <$> fromField f

instance ToField CryptoVerified where
  toField = toField . encode
instance FromField CryptoVerified where
  fromField f = do
    s :: ByteString <- fromField f
    case decode s of
      Left err -> returnError ConversionFailed f ("Couldn't deserialize CryptoVerified: " ++ err)
      Right v -> Ok v

instance ToRow LogEntry where
  toRow LogEntry{..} = [toField _leLogIndex
                       ,toField _leTerm
                       ,toField _leHash
                       ,toField $ _cmdEntry _leCommand
                       ,toField $ _cmdClientId _leCommand
                       ,toField $ _cmdRequestId _leCommand
                       ,toField $ _cmdCryptoVerified _leCommand
                       ,toField $ _cmdProvenance _leCommand
                       ]

instance FromRow LogEntry where
  fromRow = do
    leLogIndex' <- field
    leTerm' <- field
    leHash' <- field
    cmdEntry' <- field
    cmdClientId' <- field
    cmdRequestId' <- field
    cmdCryptoVerified' <- field
    cmdProvenance' <- field
    return $ LogEntry
      { _leTerm = leTerm'
      , _leLogIndex = leLogIndex'
      , _leCommand = Command
        { _cmdEntry = cmdEntry'
        , _cmdClientId = cmdClientId'
        , _cmdRequestId = cmdRequestId'
        , _cmdCryptoVerified = cmdCryptoVerified'
        , _cmdProvenance = cmdProvenance'
        }
      , _leHash = leHash'
      }

sqlDbSchema :: Query
sqlDbSchema = Query $ T.pack
  "CREATE TABLE IF NOT EXISTS 'main'.'logEntry' \
  \( 'logIndex' INTEGER PRIMARY KEY NOT NULL UNIQUE\
  \, 'term' INTEGER\
  \, 'hash' TEXT\
  \, 'commandEntry' TEXT\
  \, 'clientId' TEXT\
  \, 'requestId' INTEGER\
  \, 'cryptoVerified' TEXT\
  \, 'provenance' TEXT\
  \)"

createDB :: FilePath -> IO Connection
createDB f = do
  conn <- open f
  execute_ conn sqlDbSchema
  return conn

sqlInsertLogEntry :: Query
sqlInsertLogEntry = Query $ T.pack
    "INSERT INTO 'main'.'logEntry' \
    \( 'logIndex'\
    \, 'term'\
    \, 'hash'\
    \, 'commandEntry'\
    \, 'clientId'\
    \, 'requestId'\
    \, 'cryptoVerified'\
    \, 'provenance'\
    \) VALUES (?,?,?,?,?,?,?,?)"

insertSeqLogEntry :: Connection -> LogEntries -> IO ()
insertSeqLogEntry conn (LogEntries les) = withTransaction conn $ mapM_ (execute conn sqlInsertLogEntry) $ Map.elems les

sqlSelectAllLogEntries :: Query
sqlSelectAllLogEntries = Query $ T.pack
  "SELECT logIndex,term,hash,commandEntry,clientId,requestId,cryptoVerified,provenance\
  \ FROM 'main'.'logEntry'\
  \ ORDER BY logIndex ASC"

selectAllLogEntries :: Connection -> IO LogEntries
selectAllLogEntries conn = do
  res <- query_ conn sqlSelectAllLogEntries
  res' <- return ((\l -> (_leLogIndex l, l)) <$> res)
  return $ LogEntries . Map.fromList $ res'

sqlSelectLastLogEntry :: Query
sqlSelectLastLogEntry = Query $ T.pack
  "SELECT logIndex,term,hash,commandEntry,clientId,requestId,cryptoVerified,provenance\
  \ FROM 'main'.'logEntry'\
  \ ORDER BY logIndex DESC\
  \ LIMIT 1"

selectLastLogEntry :: Connection -> IO (Maybe LogEntry)
selectLastLogEntry conn = do
  res <- query_ conn sqlSelectLastLogEntry
  case res of
    [r] -> return $ Just r
    [] -> return $ Nothing
    err -> error $ "invariant failure: selectLastLogEntry returned more than one result\n" ++ show err

sqlSelectAllLogEntryAfter :: LogIndex -> Query
sqlSelectAllLogEntryAfter (LogIndex li) = Query $ T.pack $
  "SELECT logIndex,term,hash,commandEntry,clientId,requestId,cryptoVerified,provenance\
  \ FROM 'main'.'logEntry'\
  \ ORDER BY logIndex ASC\
  \ WHERE logIndex > " ++ show li

selectAllLogEntriesAfter :: LogIndex -> Connection -> IO LogEntries
selectAllLogEntriesAfter li conn = do
  res <- query_ conn (sqlSelectAllLogEntryAfter li)
  res' <- return ((\l -> (_leLogIndex l, l)) <$> res)
  return $ LogEntries . Map.fromList $ res'

sqlSelectLogEntriesInclusiveSection :: LogIndex -> LogIndex -> Query
sqlSelectLogEntriesInclusiveSection (LogIndex liFrom) (LogIndex liTo) = Query $ T.pack $
  "SELECT logIndex,term,hash,commandEntry,clientId,requestId,cryptoVerified,provenance\
  \ FROM 'main'.'logEntry'\
  \ ORDER BY logIndex ASC\
  \ WHERE logIndex >= " ++ show liFrom ++
  " AND logIndex <= " ++ show liTo

selectLogEntriesInclusiveSection :: LogIndex -> LogIndex -> Connection -> IO LogEntries
selectLogEntriesInclusiveSection liFrom liTo conn = do
  res <- query_ conn (sqlSelectLogEntriesInclusiveSection liFrom liTo)
  res' <- return ((\l -> (_leLogIndex l, l)) <$> res)
  return $ LogEntries . Map.fromList $ res'

sqlSelectSpecificLogEntry :: LogIndex -> Query
sqlSelectSpecificLogEntry (LogIndex li) = Query $ T.pack $
  "SELECT logIndex,term,hash,commandEntry,clientId,requestId,cryptoVerified,provenance\
  \ FROM 'main'.'logEntry'\
  \ ORDER BY logIndex ASC\
  \ WHERE logIndex == " ++ show li

selectSpecificLogEntry :: LogIndex -> Connection -> IO (Maybe LogEntry)
selectSpecificLogEntry li conn = do
  res <- query_ conn (sqlSelectSpecificLogEntry li)
  if null res
  then return Nothing
  else return $ Just $ head res
