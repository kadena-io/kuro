{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# OPTIONS_GHC -fno-cse #-}

module Main
  ( main
  ) where

import Control.Monad
import Data.Either
import Data.List.Extra
import Safe
import System.Command
import System.Console.CmdArgs
import System.Time.Extra
import Text.Printf
import Util.TestRunner

main :: IO ()
main = do
  theArgs <- cmdArgs boloArgs
  startupStuff theArgs
  ok <- case batchSize theArgs of
    1  -> runNoBatch theArgs
    _  -> runWithBatch theArgs
  case ok of
    True -> putStrLn "Run succeeded."
    False -> putStrLn "Run failed."

data BoloArgs = BoloArgs
  { transactions :: Int
  , batchSize :: Int
  , secondsTimeout :: Int
  , noRunServer :: Bool
  , configFile :: String
  , dirForConfig :: String } deriving (Show, Data, Typeable)

boloArgs :: BoloArgs
boloArgs = BoloArgs { transactions = 12000, batchSize = 3000, secondsTimeout = 30
                    , noRunServer = False, configFile = "client.yaml"
                    , dirForConfig = "executables/bolosim/conf/" }

startupStuff :: BoloArgs -> IO ()
startupStuff theArgs = do
  when (runServer theArgs) $ do
    delBoloTempFiles
    runServers' (boloServerArgs theArgs)
    putStrLn "Servers are running, sleeping for a few seconds"
    _ <- sleep 3
    putStrLn $ "Waiting for confirmation that cluster size == 4..."
    _ <- waitForMetric testMetricSize4
    return ()
  return ()

-- clean up the double-negative -- since 'noRunServer' makes the most sense as an option ...
runServer :: BoloArgs -> Bool
runServer BoloArgs{..} = not noRunServer 

----------------------------------------------------------------------------------------------------
-- TODO: After integrating the config change branch with develop, move these to
-- TestRunner.hs and remove from here and ConfigChangeSpec.hs
waitForMetric :: TestMetric -> IO Bool
waitForMetric tm = do
  t <- timeout 10 go
  return $ case t of
    Nothing -> False
    Just _ -> True
  where
    go :: IO ()
    go = do
      res <- gatherMetric tm
      when (isLeft $ getMetricResult res) go
  
getMetricResult :: TestMetricResult -> Either String String
getMetricResult result =
    case valueStr of
        Nothing -> Left $ failMetric result "Metric is missing"
        Just val -> do
            if not (evalTm req val)
              then Left $ metricNameTm req ++ ": eval failed with " ++ val
              else Right $ passMetric result
  where
    req = requestTmr result
    valueStr = valueTmr result

failMetric :: TestMetricResult -> String -> String
failMetric tmr addlInfo = unlines
    [ "Metric failure: " ++ metricNameTm (requestTmr tmr)
    , "Value received: " ++ show (valueTmr tmr)
    , "(" ++ addlInfo ++ ")"
    ]

passMetric :: TestMetricResult -> String
passMetric tmr = "Metric test passed: " ++ metricNameTm (requestTmr tmr)

testMetricSize4 :: TestMetric
testMetricSize4 = TestMetric
  { metricNameTm = "/kadena/cluster/size"
  , evalTm = (\s -> readDef (0.0 :: Float) s == 4.0) }
----------------------------------------------------------------------------------------------------
  
delBoloTempFiles :: IO ()
delBoloTempFiles = do
   let p = shell $ boloDir ++ "deleteFiles.sh"
   _ <- createProcess p
   return ()

runNoBatch :: BoloArgs -> IO Bool
runNoBatch BoloArgs{..} = undefined

runWithBatch :: BoloArgs -> IO Bool
runWithBatch theArgs@BoloArgs{..} = do
  putStrLn $ "Running " ++ show transactions ++ " transactions in batches of " ++ show batchSize
  initResults <- runClientCommands (clientArgs theArgs) initialRequests 
  let initOk = checkResults initResults
  case initOk of
    False -> return False
    True -> loop transactions True where
      loop :: Int -> Bool -> IO Bool
      loop 0 allOk = return allOk -- all done
      loop totalRemaining allOk = do -- do next batch
        (sec, (ok, nDone, sz)) <- duration $ do 
          let thisBatch = min totalRemaining batchSize
          let startNum = transactions - totalRemaining
          let batchReq = createOrdersReq startNum thisBatch secondsTimeout
          _res <- runClientCommands' (clientArgs theArgs) [batchReq] secondsTimeout
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

clientArgs :: BoloArgs -> [String]
clientArgs BoloArgs{..} = words $ "-c " ++ dirForConfig ++ configFile 

boloDir :: String
boloDir = "executables/bolosim/"

boloServerArgs :: BoloArgs -> [String]
boloServerArgs theArgs = [boloServerArgs0 theArgs, boloServerArgs1 theArgs, boloServerArgs2 theArgs, boloServerArgs3 theArgs]

boloServerArgs0, boloServerArgs1, boloServerArgs2, boloServerArgs3 :: BoloArgs -> String
boloServerArgs0 BoloArgs{..} = "-c " ++ dirForConfig ++ "10000-cluster.yaml"
boloServerArgs1 BoloArgs{..} = "-c " ++ dirForConfig ++ "10001-cluster.yaml"
boloServerArgs2 BoloArgs{..} = "-c " ++ dirForConfig ++ "10002-cluster.yaml"
boloServerArgs3 BoloArgs{..} = "-c " ++ dirForConfig ++ "10003-cluster.yaml"

initialRequests :: [TestRequest]
initialRequests = [initAccounts, initOrders, createAcctTbl, createOrdersTbl]

printEval :: TestResponse -> IO ()
printEval tr =
  case resultSuccess tr of
    False -> putStrLn $ "Evaluation failed"
    True -> return ()

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
  , eval = printEval 
  , displayStr = "Loads the initialize orders yaml file." }

initAccounts :: TestRequest
initAccounts = TestRequest
  { cmd = "load executables/bolosim/conf/initialize_accounts.yml"
  , matchCmd = "executables/bolosim/conf/initialize_accounts.yml"
  , eval = printEval 
  , displayStr = "Loads the initialize accounts yaml file." }

createAcctTbl :: TestRequest
createAcctTbl = TestRequest
  { cmd = "exec (create-table accounts.accounts)"
  , matchCmd = "exec (create-table accounts.accounts)"
  , eval = printEval 
  , displayStr = "Creates the Accounts table" }

createOrdersTbl :: TestRequest
createOrdersTbl = TestRequest
  { cmd = "exec (create-table orders.orders)"
  , matchCmd = "exec (create-table orders.orders)"
  , eval = printEval 
  , displayStr = "Creates the Orders table" }

createOrdersReq :: Int -> Int -> Int -> TestRequest
createOrdersReq startNum numOrders timeoutSecs =
  let orders = take numOrders (createOrders startNum)
  in TestRequest
       { cmd = "multiple " ++ show timeoutSecs ++ " " ++ intercalate "\n" orders
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
