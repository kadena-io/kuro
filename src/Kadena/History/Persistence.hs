{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Kadena.History.Persistence
  ( createDB
  , insertCompletedCommand
  , queryForExisting
  , selectCommpletedCommands
  ) where

import Control.Monad

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map.Strict (Map)
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

instance ToField RequestKey where
  toField n = toField $ Aeson.encode n
instance FromField RequestKey where
  fromField f = do
    s :: ByteString <- fromField f
    case Aeson.eitherDecodeStrict s of
      Left err -> returnError ConversionFailed f ("Couldn't deserialize NodeId: " ++ err)
      Right n -> Ok n

instance ToField CommandResult where
  toField n = toField $ Aeson.encode n
instance FromField CommandResult where
  fromField f = do
    s :: ByteString <- fromField f
    case Aeson.eitherDecodeStrict s of
      Left err -> returnError ConversionFailed f ("Couldn't deserialize NodeId: " ++ err)
      Right n -> Ok n

instance ToField RequestId where
  toField (RequestId rid) = toField rid
instance FromField RequestId where
  fromField f = RequestId <$> fromField f

newtype HistoryRow = HistoryRow (RequestKey, AppliedCommand) deriving (Show, Eq)

hrGetApplied :: HistoryRow -> AppliedCommand
hrGetApplied (HistoryRow (_,ac)) = ac

instance ToRow HistoryRow where
  toRow (HistoryRow (rk, ac)) =
    [toField rk
    ,toField (_acRequestId ac)
    ,toField (_acLatency ac)
    ,toField (_acResult ac)
    ]
instance FromRow HistoryRow where
  fromRow = do
    rk' <- field
    rid' <- field
    latency' <- field
    result' <- field
    return $ HistoryRow (rk', AppliedCommand rid' latency' result')

newtype RowExists = RowExists Bool deriving Show

rowExists :: RequestKey -> [RowExists] -> Bool
rowExists _ [] = False
rowExists _ [RowExists r] = r
rowExists rk o = error $ "Invariant Error: row exists should only be for a singelton list but for " ++ show rk ++ " we got " ++ show o

instance FromRow RowExists where
  fromRow = do
    (i::Int) <- field
    case i of
      i' | i' == 0 -> return $ RowExists False
      i' | i' == 1 -> return $ RowExists True
      _ -> error $ "Invariant Error in RowExists: got " ++ show i

sqlDbSchema :: Query
sqlDbSchema = Query $ T.pack
  "CREATE TABLE IF NOT EXISTS 'main'.'appliedCommands' \
  \( 'requestKey' TEXT PRIMARY KEY NOT NULL UNIQUE\
  \, 'requestId' TEXT\
  \, 'latency' INTEGER\
  \, 'commandResponse' TEXT\
  \)"

createDB :: FilePath -> IO Connection
createDB f = do
  conn <- open f
  execute_ conn sqlDbSchema
  return conn

sqlInsertHistoryRow :: Query
sqlInsertHistoryRow = Query $ T.pack
    "INSERT INTO 'main'.'appliedCommands' \
    \( 'requestKey'\
    \, 'requestId'\
    \, 'latency'\
    \, 'commandResponse'\
    \) VALUES (?,?,?,?)"

insertCompletedCommand :: Connection -> Map RequestKey AppliedCommand -> IO ()
insertCompletedCommand conn v = withTransaction conn $ mapM_ (execute conn sqlInsertHistoryRow . HistoryRow) $ Map.toList v

sqlQueryForExisting :: Query
sqlQueryForExisting = "SELECT EXISTS(SELECT 1 FROM 'main'.'appliedCommands' WHERE requestKey=:requestKey LIMIT 1)"

queryForExisting :: Connection -> Set RequestKey -> IO (Set RequestKey)
queryForExisting conn v =
  foldM (\s rk -> do { r <- queryNamed conn sqlQueryForExisting ["requestKey" := rk]
                     ; if rowExists rk r then return s else return $ Set.delete rk s}) v v

sqlSelectCompletedCommands :: Query
sqlSelectCompletedCommands =
  "SELECT requestKey,requestId,latency,commandResponse FROM 'main'.'appliedCommands' WHERE requestKey=:requestKey LIMIT 1"

selectCommpletedCommands :: Connection -> Set RequestKey -> IO (Map RequestKey AppliedCommand)
selectCommpletedCommands conn v = do
  foldM (\m rk -> do {r <- queryNamed conn sqlSelectCompletedCommands ["requestKey" := rk]
                     ; if null r
                       then return m
                       else return $ Map.insert rk (hrGetApplied $ head r) m}) Map.empty v
