{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Juno.Persistence.SQLite
  ( createDB
  , insertSeqLogEntry
  , selectAllLogEntries
  , selectAllLogEntriesAfter
  , selectLastLogEntry
  , selectLogEntriesInclusiveSection
  ) where

import Data.Typeable
import Data.Set
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Serialize
import Data.ByteString hiding (concat, length, head)
import qualified Data.Text as T

import Database.SQLite.Simple
import Database.SQLite.Simple.Ok
import Database.SQLite.Simple.ToField
import Database.SQLite.Simple.FromField

import Juno.Types

-- These live here as orphans, and not in Types, because trying to Serialize these things should be a type level error
-- with rare exception (i.e. for hashing the log entry). Moreover, accidentally sending Provenance over the wire could
-- be hard to catch. Best to make it impossible.
instance Serialize Command
instance Serialize Provenance
instance Serialize LogEntry
instance Serialize RequestVoteResponse

instance ToField NodeId where
  toField n = toField $ encode n
instance FromField NodeId where
  fromField f = do
    s :: ByteString <- fromField f
    case decode s of
      Left err -> returnError ConversionFailed f ("Couldn't deserialize sequence: " ++ err)
      Right n -> Ok n

instance ToField LogIndex where
  toField (LogIndex i) = toField i
instance FromField LogIndex where
  fromField a = LogIndex <$> fromField a

instance ToField LogEntry where
  toField LogEntry{..} = toField $ encode (_leTerm, _leCommand, _leHash)

instance ToField Term where
  toField (Term a) = toField a
instance FromField Term where
  fromField a = Term <$> fromField a

instance Serialize a => ToField (Seq a) where
  toField s = toField $ encode s
instance (Typeable a, Serialize a) => FromField (Seq a) where
  fromField f = do
    s :: ByteString <- fromField f
    case decode s of
      Left err -> returnError ConversionFailed f ("Couldn't deserialize sequence: " ++ err)
      Right v -> Ok v

instance (Ord a, Serialize a) => ToField (Set a) where
  toField s = toField $ encode s
instance (Ord a, Typeable a, Serialize a) => FromField (Set a) where
  fromField f = do
    s :: ByteString <- fromField f
    case decode s of
      Left err -> returnError ConversionFailed f ("Couldn't deserialize sequence: " ++ err)
      Right v -> Ok v

instance ToField Provenance where
  toField = toField . encode
instance FromField Provenance where
  fromField f = do
    s :: ByteString <- fromField f
    case decode s of
      Left err -> returnError ConversionFailed f ("Couldn't deserialize sequence: " ++ err)
      Right v -> Ok v

instance ToRow LogEntry where
  toRow LogEntry{..} = [toField _leLogIndex
                       ,toField _leTerm
                       ,toField _leHash
                       ,toField $ unCommandEntry $ _cmdEntry _leCommand
                       ,toField $ _cmdClientId _leCommand
                       ,toField $ _unRequestId $ _cmdRequestId _leCommand
                       ,toField $ unAlias <$> _cmdEncryptGroup _leCommand
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
    cmdEncryptGroup' <- field
    cmdProvenance' <- field
    return $ LogEntry
      { _leTerm = leTerm'
      , _leLogIndex = leLogIndex'
      , _leCommand = Command
        { _cmdEntry = CommandEntry cmdEntry'
        , _cmdClientId = cmdClientId'
        , _cmdRequestId = RequestId cmdRequestId'
        , _cmdEncryptGroup = Alias <$> cmdEncryptGroup'
        , _cmdProvenance = cmdProvenance'
        }
      , _leHash = leHash'
      }

sqlDbSchema :: Query
sqlDbSchema = Query $ T.pack $ concat
    ["CREATE TABLE IF NOT EXISTS 'main'.'logEntry' "
    ,"( 'logIndex' INTEGER PRIMARY KEY NOT NULL UNIQUE"
    ,", 'term' INTEGER"
    ,", 'hash' TEXT"
    ,", 'commandEntry' TEXT"
    ,", 'clientId' TEXT"
    ,", 'requestId' INTEGER"
    ,", 'encryptGroup' TEXT"
    ,", 'provenance' TEXT"
    ,")"]

createDB :: FilePath -> IO Connection
createDB f = do
  conn <- open f
  execute_ conn sqlDbSchema
  return conn

sqlInsertLogEntry :: Query
sqlInsertLogEntry = Query $ T.pack $ concat
    ["INSERT INTO 'main'.'logEntry' "
    ,"( 'logIndex'"
    ,", 'term'"
    ,", 'hash'"
    ,", 'commandEntry'"
    ,", 'clientId'"
    ,", 'requestId'"
    ,", 'encryptGroup'"
    ,", 'provenance'"
    ,") VALUES (?,?,?,?,?,?,?,?)"]

insertSeqLogEntry :: Connection -> Seq LogEntry -> IO ()
insertSeqLogEntry conn les = withTransaction conn $ mapM_ (execute conn sqlInsertLogEntry) les

sqlSelectAllLogEntries :: Query
sqlSelectAllLogEntries = Query $ T.pack $ concat
  ["SELECT 'logIndex','term','hash','commandEntry','clientId','requestId','encryptGroup','provenance'"
  ,"FROM 'main'.'logEntry'"
  ,"ORDER BY logIndex ASC"]

selectAllLogEntries :: Connection -> IO (Seq LogEntry)
selectAllLogEntries conn = Seq.fromList <$> query_ conn sqlSelectAllLogEntries

sqlSelectLastLogEntry :: Query
sqlSelectLastLogEntry = Query $ T.pack $ concat
  ["SELECT 'logIndex','term','hash','commandEntry','clientId','requestId','encryptGroup','provenance'"
  ,"FROM 'main'.'logEntry'"
  ,"ORDER BY logIndex DESC"
  ,"LIMIT 1"]

selectLastLogEntry :: Connection -> IO (Maybe LogEntry)
selectLastLogEntry conn = do
  res <- query_ conn sqlSelectLastLogEntry
  case res of
    [r] -> return $ Just r
    [] -> return $ Nothing
    err -> error $ "invariant failure: selectLastLogEntry returned more than one result\n" ++ show err

sqlSelectAllLogEntryAfter :: LogIndex -> Query
sqlSelectAllLogEntryAfter (LogIndex li) = Query $ T.pack $ concat
  ["SELECT 'logIndex','term','hash','commandEntry','clientId','requestId','encryptGroup','provenance'"
  ,"FROM 'main'.'logEntry'"
  ,"ORDER BY logIndex ASC"
  ,"WHERE logIndex > " ++ show li]

selectAllLogEntriesAfter :: LogIndex -> Connection -> IO (Seq LogEntry)
selectAllLogEntriesAfter li conn = Seq.fromList <$> query_ conn (sqlSelectAllLogEntryAfter li)

sqlSelectLogEntryeInclusiveSection :: LogIndex -> LogIndex -> Query
sqlSelectLogEntryeInclusiveSection (LogIndex liFrom) (LogIndex liTo) = Query $ T.pack $ concat
  ["SELECT 'logIndex','term','hash','commandEntry','clientId','requestId','encryptGroup','provenance'"
  ,"FROM 'main'.'logEntry'"
  ,"ORDER BY logIndex ASC"
  ,"WHERE logIndex >= " ++ show liFrom
  ,"AND logIndex <= " ++ show liTo]

selectLogEntriesInclusiveSection :: LogIndex -> LogIndex -> Connection -> IO (Seq LogEntry)
selectLogEntriesInclusiveSection liFrom liTo conn = Seq.fromList <$> query_ conn (sqlSelectLogEntryeInclusiveSection liFrom liTo)
