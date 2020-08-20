{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# OPTIONS_GHC -fno-cse #-}

module Pact.Persist.Inserts
  ( main
  ) where

import Control.Concurrent.Async (wait)
import Control.Concurrent.MVar
import Control.Monad

import qualified Data.Map.Strict as M
import System.Console.CmdArgs
import System.CPUTime
import System.Directory
import System.Time.Extra
import Text.Printf

import Pact.Persist
import qualified Pact.Persist.CacheAdapter as CA
import qualified Pact.Persist.Pure as Pure
import qualified Pact.Persist.SQLite as SLite
import qualified Pact.Persist.WriteBehind as WB
import qualified Pact.Persist.MySQL as MyS
import Pact.PersistPactDb
import Pact.Types.Logger
import Pact.Types.PactValue
import Pact.Types.Runtime

main :: IO ()
main = do
  theArgs <- cmdArgs insertArgs
  doInserts theArgs

data DBType = Sqlite | MySQL | PureDB | SqliteWB | MySqlWB
  deriving (Data, Show)

data InsertArgs = InsertArgs
  { transactionCount :: Integer
  , dbType :: DBType }
  deriving (Show, Data, Typeable)

insertArgs :: InsertArgs
insertArgs = InsertArgs
  { transactionCount = 1000 &= help "Number of insert transactions to run"
  , dbType = enum
    [ Sqlite &= help "Run test using Sqlite" &= name "s" &= name "sqlite"
    , MySQL &= help "Run test using MySql" &= name "m" &= name "mysql"
    , PureDB &= help "Run test using in-memory database" &= name "p" &= name "puredb"
    , SqliteWB &= help "Run test using write-behind (with Sqlite)" &= name "ws" &= name "sqlitewb"
    , MySqlWB &= help "Run test using write-behind (with MySql)" &= name "wm" &= name "mysqlwb"] }

doInserts :: InsertArgs -> IO ()
doInserts InsertArgs{..} = do
  case dbType of
    PureDB   -> do
      putStrLn $ "Using in-memory database to insert " ++ show transactionCount ++ " records"
      insertMultiple setupPureDB transactionCount
    SqliteWB -> do
      putStrLn $ "Using Sqllite with write-back to insert " ++ show transactionCount ++ " records"
      (dbe, ctx) <- setupSqliteWB
      insertMultiple (return dbe) transactionCount
      -- enqueue the command to stop the underlying database thread
      WB.enqueueStop (CA._ccWriteBehind ctx) "End of insert test"
      -- wait for the underlying thread to exit
      wait $ CA._ccAsync ctx
    MySQL -> do
      putStrLn $ "Using MySQL database. to insert " ++ show transactionCount ++ " records"
      insertMultiple setupMySQL transactionCount
    MySqlWB -> do
      putStrLn $ "Using MySQL with write-back to insert " ++ show transactionCount ++ " records"
      (dbe, ctx) <- setupMySqlWB
      insertMultiple (return dbe) transactionCount
      -- enqueue the command to stop the underlying database thread
      WB.enqueueStop (CA._ccWriteBehind ctx) "End of insert test"
      -- wait for the underlying thread to exit
      wait $ CA._ccAsync ctx
    _          -> do -- Sqlite and default
      putStrLn $ "Using Sqllite database to insert " ++ show transactionCount ++ " records"
      insertMultiple setupSqlite transactionCount

setupSqlite :: IO (MVar (DbEnv SLite.SQLite))
setupSqlite = do
  let f = "log/db.sqllite"
  doesFileExist f >>= \b -> when b (removeFile f)
  sl <- SLite.initSQLite (SLite.SQLiteConfig f fastSqlitePragmas) neverLog
  let dbe = initDbEnv neverLog SLite.persister sl
  setupEnv dbe

setupSqliteWB :: IO ( MVar (DbEnv (WB.WB (CA.CacheAdapter Pure.PureDb) SLite.SQLite))
                    , CA.CacheContext (CA.CacheAdapter Pure.PureDb) SLite.SQLite)
setupSqliteWB = do
  (dbe, context) <- CA.initTestPureSQLite "log/wb.sqlite" neverLog
  mv <- setupEnv dbe
  return (mv, context)

setupMySqlWB :: IO ( MVar (DbEnv (WB.WB (CA.CacheAdapter Pure.PureDb) MyS.MySQL))
                    , CA.CacheContext (CA.CacheAdapter Pure.PureDb) MyS.MySQL)
setupMySqlWB = do
  (dbe, context) <- CA.initTestPureMySQL neverLog
  mv <- setupEnv dbe
  return (mv, context)

setupPureDB :: IO (MVar (DbEnv Pure.PureDb))
setupPureDB = do
  let pdb = initDbEnv neverLog Pure.persister Pure.initPureDb
  setupEnv pdb

setupMySQL :: IO (MVar (DbEnv MyS.MySQL))
setupMySQL = do
  mysql <- MyS.initMySQL MyS.testConnectInfo neverLog
  MyS.dropRegressTables mysql
  let dbe = initDbEnv neverLog MyS.persister mysql
  setupEnv dbe

table :: TableName
table = "table"

setupEnv :: DbEnv p -> IO (MVar (DbEnv p))
setupEnv dbe = do
  v <- (newMVar dbe)
  createSchema v
  _ <- _beginTx pactdb Transactional v
  createUserTable' v table "aModule"
  _ <- _commitTx pactdb v
  return v

insertMultiple :: IO (MVar (DbEnv a)) -> Integer -> IO ()
insertMultiple ioMVarEnv count = do
  (sec, ()) <- duration $ do
    mVarEnv <- ioMVarEnv
    t <- getCPUTime
    let t' = fromIntegral t
    let txIds = [t', t'+1.. t'+count]
    mapM_ (insertOne mVarEnv) txIds
  let seconds = printf "%.2f" sec :: String
  let tPerSec = printf "%.2f" (fromIntegral count / sec) :: String
  putStrLn $ show count ++ " inserts completed in: " ++ show seconds ++ " seconds "
              ++ "(" ++ tPerSec ++ " per second)"

insertOne :: MVar (DbEnv p) -> Integer -> IO ()
insertOne env n = do
  _ <- _beginTx pactdb Transactional env
  let ut = UserTables table
  _writeRow pactdb Write ut "key1"
    (ObjectMap (M.fromList
      [ ("tx",PLiteral (LInteger (fromIntegral n)))
      , ("dec", PLiteral (LDecimal 23.456))
      , ("string", PLiteral (LString "This sentence seems reasonable."))
      ] )
    ) env
  _ <- _readRow pactdb ut "key1" env
  void $ _commitTx pactdb env

-- TODO: Do we want to move Pact's SQLite module to part-persist?  For now, duplicating
-- 'fastNoJournalPragmas' from Pact (avoiding having to modify Pact in order to export this)
fastSqlitePragmas :: [SLite.Pragma]
fastSqlitePragmas = [
  "synchronous = OFF",
  "journal_mode = MEMORY",
  "locking_mode = EXCLUSIVE",
  "temp_store = MEMORY"
  ]
