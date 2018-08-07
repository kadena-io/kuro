{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# OPTIONS_GHC -fno-cse #-}

module Main
  ( main
  ) where

import Data.List.Extra
import System.Command
import System.Console.CmdArgs
import System.Time.Extra
import Text.Printf
import Util.TestRunner

main :: IO ()
main = do
  theArgs <- cmdArgs boloArgs
  startupStuff
  ok <- case batchSize theArgs of
    1  -> runNoBatch (numTransactions theArgs)
    _  -> runWithBatch (numTransactions theArgs) (batchSize theArgs)
  case ok of
    True -> putStrLn "Run succeeded."
    False -> putStrLn "Run failed."

data BoloArgs = BoloArgs {numTransactions :: Int, batchSize :: Int} deriving (Show, Data, Typeable)

boloArgs :: BoloArgs
boloArgs = BoloArgs {numTransactions = 12000, batchSize = 4000}

startupStuff :: IO ()
startupStuff = do
  delBoloTempFiles
  runServers' boloServerArgs
  putStrLn "Servers are running, sleeping for a few seconds"
  _ <- sleep 3
  return ()

delBoloTempFiles :: IO ()
delBoloTempFiles = do
    let p = shell $ boloDir ++ "deleteFiles.sh"
    _ <- createProcess p
    return ()

runNoBatch :: Int -> IO Bool
runNoBatch _nTrans = undefined

runWithBatch :: Int -> Int -> IO Bool
runWithBatch nTransactions batchSz = do
  putStrLn $ "Running " ++ show nTransactions ++ " transactions in batches of " ++ show batchSz
  initResults <- runClientCommands clientArgs initialRequests
  let initOk = checkResults initResults
  case initOk of
    False -> return False
    True -> loop nTransactions True where
      loop :: Int -> Bool -> IO Bool
      loop 0 allOk = return allOk -- all done
      loop totalRemaining allOk = do -- do next batch
        (sec, (ok, nDone, sz)) <- duration $ do 
          let thisBatch = min totalRemaining batchSz
          let startNum = nTransactions - totalRemaining
          let batchReq = createOrdersReq startNum thisBatch
          _res <- runClientCommands clientArgs [batchReq]
          return (True, startNum+thisBatch, thisBatch) -- checkResults res
        let seconds = printf "%.2f" sec :: String
        let tPerSec = printf "%.2f" (fromIntegral sz / sec) :: String
        putStrLn $ show nDone ++ " completed -- this batch of " ++ show sz ++ " transactions "
                   ++ "completed in: " ++ show seconds ++ " seconds "
                   ++ "(" ++ tPerSec ++ " per second)" 
        loop (totalRemaining-sz) (allOk && ok)
  
checkResults :: [TestResult] -> Bool
checkResults xs = and $ fmap checkResult xs

checkResult :: TestResult -> Bool
checkResult x =
  case responseTr x of
    Nothing -> False
    Just resp -> resultSuccess resp

clientArgs :: [String]
clientArgs = words $ "-c " ++ boloConfDir ++ "client.yaml"

boloDir :: String
boloDir = "executables/bolosim/"

boloConfDir :: String
boloConfDir = "executables/bolosim/conf/"

boloServerArgs :: [String]
boloServerArgs = [boloServerArgs0, boloServerArgs1, boloServerArgs2, boloServerArgs3]

boloServerArgs0, boloServerArgs1, boloServerArgs2, boloServerArgs3 :: String
boloServerArgs0 = "-c " ++ boloConfDir ++ "10000-cluster.yaml"
boloServerArgs1 = "-c " ++ boloConfDir ++ "10001-cluster.yaml"
boloServerArgs2 = "-c " ++ boloConfDir ++ "10002-cluster.yaml"
boloServerArgs3 = "-c " ++ boloConfDir ++ "10003-cluster.yaml"

initialRequests :: [TestRequest]
initialRequests = [initAccounts, initOrders, createAcctTbl, createOrdersTbl]

_testReq :: TestRequest
_testReq = TestRequest
  { cmd = "exec (+ 1 1)"
  , matchCmd = "exec (+ 1 1)"
  , eval = \_ -> return () -- not used in this sim
  , displayStr = "Executes 1 + 1 in Pact" }

initOrders :: TestRequest
initOrders = TestRequest
  { cmd = "load executables/bolosim/conf/initialize_orders.yml"
  , matchCmd = "executables/bolosim/conf/initialize_orders.yml"
  , eval = \_ -> return () -- not used in this sim
  , displayStr = "Loads the initialize orders yaml file." }

initAccounts :: TestRequest
initAccounts = TestRequest
  { cmd = "load executables/bolosim/conf/initialize_accounts.yml"
  , matchCmd = "executables/bolosim/conf/initialize_accounts.yml"
  , eval = \_ -> return () -- not used in this sim
  , displayStr = "Loads the initialize accounts yaml file." }

createAcctTbl :: TestRequest
createAcctTbl = TestRequest
  { cmd = "exec (create-table accounts.accounts)"
  , matchCmd = "exec (create-table accounts.accounts)"
  , eval = \_ -> return () -- not used in this sim
  , displayStr = "Creates the Accounts table" }

createOrdersTbl :: TestRequest
createOrdersTbl = TestRequest
  { cmd = "exec (create-table orders.orders)"
  , matchCmd = "exec (create-table orders.orders)"
  , eval = \_ -> return () -- not used in this sim
  , displayStr = "Creates the Orders table" }

createOrdersReq :: Int -> Int -> TestRequest
createOrdersReq startNum numOrders =
  let orders = take numOrders (createOrders startNum)
  in TestRequest
       { cmd = "multiple " ++ intercalate "\n" orders
       , matchCmd = "TBD" -- MLN: need to find what the match str format is
       , eval = \_ -> return () -- not used in this sim
       , displayStr = "Creates an order." }

createOrders :: Int -> [String]
createOrders 0 = fmap createOrder [1,2..]
createOrders start = fmap createOrder [start+1,(start+2)..]

createOrder :: Int -> String
createOrder n =
  "(orders.create-order"
  ++ " " ++ escN n "order-id-"
  ++ " " ++ esc "some-keyset"
  ++ " " ++ escN n "record-id-"
  ++ " " ++ escN n "hash-"
  ++ " " ++ escN n "npi-"
  ++ " " ++ "(time " ++ esc "2015-01-01T00:00:00Z" ++ ")"
  ++ " " ++ escN n "CHANNEL_"
  ++ " " ++ esc ( takeEnd 4 (show (1000 + n)))
  ++ " " ++ escN n "user-id-"
  ++ " " ++ escN n "Comment number "
  ++ " " ++ "(time " ++ esc "2018-01-01T00:00:00Z" ++ ")"
  ++ ")"

esc :: String -> String
esc s = "\"" ++ s ++ "\""

escN :: Int -> String -> String
escN n s = "\"" ++ s ++ show n ++ "\""
