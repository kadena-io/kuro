{-# LANGUAGE RecordWildCards #-}
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
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base16 as B16

import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap

import Database.SQLite3.Direct

import Kadena.Types.Base
import Kadena.Types.Command
import Kadena.Types.Sqlite
import Kadena.History.Types

rkToField :: RequestKey -> SType
rkToField (RequestKey (Hash rk)) = SText $ Utf8 $ B16.encode rk

crToField :: CommandResult -> SType
crToField = SBlob . unCommandResult

crFromField :: ByteString -> CommandResult
crFromField = CommandResult

riToField :: RequestId -> SType
riToField (RequestId s) = SText $ Utf8 $ encodeUtf8 $ T.pack s

riFromField :: Utf8 -> RequestId
riFromField (Utf8 s) = RequestId $ T.unpack $ decodeUtf8 s


sqlDbSchema :: Utf8
sqlDbSchema =
  "CREATE TABLE IF NOT EXISTS 'main'.'appliedCommands' \
  \( 'requestKey' TEXT PRIMARY KEY NOT NULL UNIQUE\
  \, 'requestId' TEXT\
  \, 'latency' INTEGER\
  \, 'commandResponse' BLOB\
  \)"

eitherToError :: Show e => String -> Either e a -> a
eitherToError _ (Right v) = v
eitherToError s (Left e) = error $ "SQLite Error in History exec: " ++ s ++ "\nWith Error: "++ show e

createDB :: FilePath -> IO DbEnv
createDB f = do
  conn <- eitherToError "OpenDB" <$> open (Utf8 $ encodeUtf8 $ T.pack f)
  eitherToError "CreateTable" <$> exec conn sqlDbSchema
  eitherToError "pragmas" <$> exec conn "PRAGMA locking_mode = EXCLUSIVE"
  DbEnv <$> pure conn
      <*> prepStmt conn sqlInsertHistoryRow
      <*> prepStmt conn sqlQueryForExisting
      <*> prepStmt conn sqlSelectCompletedCommands

sqlInsertHistoryRow :: Utf8
sqlInsertHistoryRow =
    "INSERT INTO 'main'.'appliedCommands' \
    \( 'requestKey'\
    \, 'requestId'\
    \, 'latency'\
    \, 'commandResponse'\
    \) VALUES (?,?,?,?)"


insertRow :: Statement -> (RequestKey, AppliedCommand) -> IO ()
insertRow s (k,AppliedCommand {..}) =
    execs s [rkToField k
            ,riToField _acRequestId
            ,SInt _acLatency
            ,crToField _acResult]


insertCompletedCommand :: DbEnv -> HashMap RequestKey AppliedCommand -> IO ()
insertCompletedCommand DbEnv{..} v = do
  eitherToError "start insert transaction" <$> exec _conn "BEGIN TRANSACTION"
  mapM_ (insertRow _insertStatement) $ HashMap.toList v
  eitherToError "end insert transaction" <$> exec _conn "END TRANSACTION"

sqlQueryForExisting :: Utf8
sqlQueryForExisting = "SELECT EXISTS(SELECT 1 FROM 'main'.'appliedCommands' WHERE requestKey=:requestKey LIMIT 1)"


queryForExisting :: DbEnv -> HashSet RequestKey -> IO (HashSet RequestKey)
queryForExisting e v = foldM f v v where
    f s rk = do
      r <- qrys (_qryExistingStmt e) [rkToField rk] [RInt]
      case r of
        [[SInt 1]] -> return s
        _ -> return $ HashSet.delete rk s

sqlSelectCompletedCommands :: Utf8
sqlSelectCompletedCommands =
  "SELECT requestKey,requestId,latency,commandResponse FROM 'main'.'appliedCommands' WHERE requestKey=:requestKey LIMIT 1"

selectCompletedCommands :: DbEnv -> HashSet RequestKey -> IO (HashMap RequestKey AppliedCommand)
selectCompletedCommands e v = foldM f HashMap.empty v where
    f m rk = do
      rs <- qrys (_qryCompletedStmt e) [rkToField rk] [RText,RText,RInt,RBlob]
      if null rs
      then return m
      else case head rs of
          [_,SText rid,SInt lat,SBlob cr] ->
            return $ HashMap.insert rk (AppliedCommand (crFromField cr) lat (riFromField rid)) m
          r -> dbError $ "Invalid result from query: " ++ show r
