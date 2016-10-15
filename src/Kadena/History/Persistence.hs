{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Kadena.History.Persistence
--  ( createDB
--  , insertCompletedCommand
--  , queryForExisting
--  , selectCompletedCommands
--  ) where

  where

import Control.Monad

import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Base16 as B16

import Data.Maybe (fromMaybe)

import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap

import Database.SQLite3.Direct

import Kadena.Types

data PSL = PSL
  { _conn :: Database
  , _insertStatement :: Statement
  }


rkToField :: RequestKey -> Utf8
rkToField (RequestKey (Hash rk)) = Utf8 $ B16.encode rk

rkFromField :: Utf8 -> RequestKey
rkFromField (Utf8 f) = case B16.decode f of
      (s',leftovers) | leftovers == B.empty -> RequestKey $ Hash s'
                     | otherwise -> error $ "Couldn't deserialize RequestKey" ++ show (f,s',leftovers)

crToField :: CommandResult -> ByteString
crToField = unCommandResult

crFromField :: ByteString -> CommandResult
crFromField = CommandResult

riToField :: RequestId -> Utf8
riToField (RequestId s) = Utf8 $ encodeUtf8 $ T.pack s

riFromField :: Utf8 -> RequestId
riFromField (Utf8 s) = RequestId $ T.unpack $ decodeUtf8 s

bindRow :: Statement -> (RequestKey, AppliedCommand) -> IO ()
bindRow s full@(rk, AppliedCommand{..}) = do
  clearBindings s
  eitherToError ("binding RK: " ++ show full) <$> bindText s 1 (rkToField rk)
  eitherToError ("binding RI: " ++ show full) <$> bindText s 2 (riToField _acRequestId)
  eitherToError ("binding Lat: " ++ show full) <$> bindInt64 s 3 _acLatency
  eitherToError ("binding CR: " ++ show full) <$> bindBlob s 4 (crToField _acResult)

--newtype HistoryRow = HistoryRow (RequestKey, AppliedCommand) deriving (Show, Eq)

--hrGetApplied :: HistoryRow -> AppliedCommand
--hrGetApplied (HistoryRow (_,ac)) = ac
--
--instance ToRow HistoryRow where
--  toRow (HistoryRow (rk, ac)) =
--    [toField rk
--    ,toField (_acRequestId ac)
--    ,toField (_acLatency ac)
--    ,toField (_acResult ac)
--    ]
--instance FromRow HistoryRow where
--  fromRow = do
--    rk' <- field
--    rid' <- field
--    latency' <- field
--    result' <- field
--    return $ HistoryRow (rk', AppliedCommand { _acResult = result'
--                                             , _acLatency = latency'
--                                             , _acRequestId = rid'})
--
newtype RowExists = RowExists Bool deriving Show

rowExists :: RequestKey -> [RowExists] -> Bool
rowExists _ [] = False
rowExists _ [RowExists r] = r
rowExists rk o = error $ "Invariant Error: row exists should only be for a singelton list but for " ++ show rk ++ " we got " ++ show o

--instance FromRow RowExists where
--  fromRow = do
--    (i::Int) <- field
--    case i of
--      i' | i' == 0 -> return $ RowExists False
--      i' | i' == 1 -> return $ RowExists True
--      _ -> error $ "Invariant Error in RowExists: got " ++ show i

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

createDB :: FilePath -> IO PSL
createDB f = do
  conn <- eitherToError "OpenDB" <$> open (Utf8 $ encodeUtf8 $ T.pack f)
  eitherToError "CreateTable" <$> exec conn sqlDbSchema
  eitherToError "pragmas" <$> exec conn "PRAGMA locking_mode = EXCLUSIVE"
  iStmt <- stmtInsertHistoryRow conn
  return $ PSL
    { _conn = conn
    , _insertStatement = iStmt
    }

stmtInsertHistoryRow :: Database -> IO Statement
stmtInsertHistoryRow d = do
  let s = Utf8
            "INSERT INTO 'main'.'appliedCommands' \
            \( 'requestKey'\
            \, 'requestId'\
            \, 'latency'\
            \, 'commandResponse'\
            \) VALUES (?,?,?,?)"
  fromMaybe (error "Generically failed to create statement!") . eitherToError "Insert Statment Prep" <$> prepare d s

insertRow :: Database -> Statement -> (RequestKey, AppliedCommand) -> IO ()
insertRow = undefined

insertCompletedCommand :: PSL -> HashMap RequestKey AppliedCommand -> IO ()
insertCompletedCommand PSL{..} v = do
  eitherToError "start insert transaction" <$> exec _conn "BEGIN TRANSACTION"
  mapM_ (insertRow _conn _insertStatement) $ HashMap.toList v
  eitherToError "end insert transaction" <$> exec _conn "END TRANSACTION"

--sqlQueryForExisting :: Query
--sqlQueryForExisting = "SELECT EXISTS(SELECT 1 FROM 'main'.'appliedCommands' WHERE requestKey=:requestKey LIMIT 1)"
--
--queryForExisting :: Connection -> HashSet RequestKey -> IO (HashSet RequestKey)
--queryForExisting conn v =
--  foldM (\s rk -> do { r <- queryNamed conn sqlQueryForExisting [":requestKey" := rk]
--                     ; if rowExists rk r then return s else return $ HashSet.delete rk s}) v v
--
--sqlSelectCompletedCommands :: Query
--sqlSelectCompletedCommands =
--  "SELECT requestKey,requestId,latency,commandResponse FROM 'main'.'appliedCommands' WHERE requestKey=:requestKey LIMIT 1"
--
--selectCompletedCommands :: Connection -> HashSet RequestKey -> IO (HashMap RequestKey AppliedCommand)
--selectCompletedCommands conn v = do
--  foldM (\m rk -> do {r <- queryNamed conn sqlSelectCompletedCommands [":requestKey" := rk]
--                     ; if null r
--                       then return m
--                       else return $ HashMap.insert rk (hrGetApplied $ head r) m}) HashMap.empty v
