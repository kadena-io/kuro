{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Kadena.History.Persistence
  ( createDB
  , insertCompletedCommand
  , queryForExisting
  , selectCompletedCommands
  ) where

import Control.Monad

import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16

import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap

import Database.SQLite.Simple
import Database.SQLite.Simple.ToField
import Database.SQLite.Simple.FromField

import Kadena.Types

instance ToField RequestKey where
  toField (RequestKey (Hash rk)) = toField $ toB16Text rk
instance FromField RequestKey where
  fromField f = do
    s :: T.Text <- fromField f
    case B16.decode (encodeUtf8 s) of
      (s',leftovers) | leftovers == B.empty -> return $ RequestKey $ Hash s'
                     | otherwise -> returnError ConversionFailed f ("Couldn't deserialize RequestKey" ++ show (s,s',leftovers))

instance ToField CommandResult where
  toField (CommandResult r) = toField r
instance FromField CommandResult where
  fromField f = CommandResult <$> fromField f

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
    return $ HistoryRow (rk', AppliedCommand { _acResult = result'
                                             , _acLatency = latency'
                                             , _acRequestId = rid'})

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
  \, 'commandResponse' BLOB\
  \)"

createDB :: FilePath -> IO Connection
createDB f = do
  conn <- open f
  execute_ conn sqlDbSchema
  execute_ conn "PRAGMA locking_mode = EXCLUSIVE"
  return conn

sqlInsertHistoryRow :: Query
sqlInsertHistoryRow = Query $ T.pack
    "INSERT INTO 'main'.'appliedCommands' \
    \( 'requestKey'\
    \, 'requestId'\
    \, 'latency'\
    \, 'commandResponse'\
    \) VALUES (?,?,?,?)"

insertCompletedCommand :: Connection -> HashMap RequestKey AppliedCommand -> IO ()
insertCompletedCommand conn v = withTransaction conn $ mapM_ (execute conn sqlInsertHistoryRow . HistoryRow) $ HashMap.toList v

sqlQueryForExisting :: Query
sqlQueryForExisting = "SELECT EXISTS(SELECT 1 FROM 'main'.'appliedCommands' WHERE requestKey=:requestKey LIMIT 1)"

queryForExisting :: Connection -> HashSet RequestKey -> IO (HashSet RequestKey)
queryForExisting conn v =
  foldM (\s rk -> do { r <- queryNamed conn sqlQueryForExisting [":requestKey" := rk]
                     ; if rowExists rk r then return s else return $ HashSet.delete rk s}) v v

sqlSelectCompletedCommands :: Query
sqlSelectCompletedCommands =
  "SELECT requestKey,requestId,latency,commandResponse FROM 'main'.'appliedCommands' WHERE requestKey=:requestKey LIMIT 1"

selectCompletedCommands :: Connection -> HashSet RequestKey -> IO (HashMap RequestKey AppliedCommand)
selectCompletedCommands conn v = do
  foldM (\m rk -> do {r <- queryNamed conn sqlSelectCompletedCommands [":requestKey" := rk]
                     ; if null r
                       then return m
                       else return $ HashMap.insert rk (hrGetApplied $ head r) m}) HashMap.empty v
