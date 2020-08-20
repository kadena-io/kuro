{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Pact.Persist.Bench where

import Criterion.Main

import Pact.PersistPactDb.Regression
import Control.DeepSeq
import System.Directory
import Control.Monad
import System.CPUTime
import Control.Concurrent.MVar
import qualified Data.Map.Strict as M
import qualified Data.ByteString.Lazy as BSL
import Data.Aeson (encode)
import Data.String.Conv (toS)

import qualified Pact.Persist.Pure as Pure
import qualified Pact.Persist.SQLite as SQLite
import qualified Pact.Persist.WriteBehind as WB
import qualified Pact.Persist.CacheAdapter as CA
import Pact.Persist
import Pact.PersistPactDb
import Pact.Types.PactValue
import Pact.Types.Runtime as P
import Pact.Types.Logger

data Benchy = Benchy {
  bPure :: MVar (DbEnv Pure.PureDb),
  bSQLite :: MVar (DbEnv SQLite.SQLite),
  bWB :: MVar (DbEnv (WB.WB (CA.CacheAdapter Pure.PureDb) SQLite.SQLite))
  }

instance NFData Benchy where
  rnf Benchy {..} = bPure `seq` bSQLite `seq` bWB `seq` ()

out :: String -> IO ()
out _ = return ()

setup :: IO Benchy
setup = Benchy <$>
  (let pdb = initDbEnv neverLog Pure.persister Pure.initPureDb
   in setupBench pdb)
  <*>
  (do
      let f = "log/db.sqllite"
      doesFileExist f >>= \b -> when b (removeFile f)
      sl <- SQLite.initSQLite (SQLite.SQLiteConfig f []) neverLog
      let dbe = initDbEnv neverLog SQLite.persister sl
      setupBench dbe)
  <*>
  (do
      (dbe, _ctx) <- CA.initTestPureSQLite "log/wb.sqlite" neverLog
      setupBench dbe)

table :: TableName
table = "table"

setupBench :: DbEnv p -> IO (MVar (DbEnv p))
setupBench dbe = do
  v <- newMVar dbe
  createSchema v
  _ <- _beginTx pactdb Transactional v
  createUserTable' v table "aModule"
  void $ _commitTx pactdb v
  return v

main :: IO ()
main = defaultMain [
  env setup $ \ ~(Benchy pureEnv sqliteEnv wbEnv) -> bgroup "all" [
      bench "pure" $ whnfIO $ runBench pureEnv,
      bench "sqlite" $ whnfIO $ runBench sqliteEnv,
      bench "wb" $ whnfIO $ runBench wbEnv
      ]]

runBench :: MVar (DbEnv p) -> IO String
runBench s = do
  t <- getCPUTime
  _ <- _beginTx pactdb Transactional s
  let ut = UserTables table
  _writeRow pactdb Write ut "key1"
    (ObjectMap $ M.fromList
     [("tx",PLiteral (LInteger (fromIntegral t))),
       ("dec", PLiteral (LDecimal 23.456)),
      ("string", PLiteral (LString "lasdjfhas lkjfh asdkjsfh aslkjhwuetvmxn"))])
    s
  r2 <- _readRow pactdb ut "key1" s
  logs <- _commitTx pactdb s
  return $ show (BSL.length $ encode r2) ++ ": " ++ (show (P.pactHash (toS (show logs))))

testSetup :: IO ()
testSetup = do
  Benchy p s wb <- setup
  putStrLn =<< runBench p
  putStrLn =<< runBench s
  putStrLn =<< runBench wb
