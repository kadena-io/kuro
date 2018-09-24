{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# OPTIONS_GHC -fno-cse #-}

module Main
  ( main
  ) where

import Control.Monad
import Data.Either
import Safe
import System.Command
import System.Console.CmdArgs
import System.Time.Extra
import Text.Printf

import Apps.Kadena.Client (esc)
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
  , cmdFile :: String
  , noRunServer :: Bool
  , configFile :: String
  , dirForConfig :: String
  , enableDiagnostics :: Bool }
  deriving (Show, Data, Typeable)

boloArgs :: BoloArgs
boloArgs = BoloArgs
  { transactions = 120000 &= name "t" &= help "Number of transactions to run"
  , batchSize = 3000 &= name "b" &= name "batchsize" &= help "Number of transactions in each batch"
  , cmdFile = "" &= name "p" &= name "cmdfile" &= help "File with templated Pact command"
  , noRunServer = False &= name "n" &= name "norunserver" &= help "Flag specifying this exe should not launch Kadena server instances"
  , configFile = "client.yaml" &= name "c" &= name "configfile" &= help "Kadena config file"
  , dirForConfig = "executables/bolosim/conf/" &= name "d" &= name "dirForConfig" &= help "Location of config files"
  , enableDiagnostics = False &= name "e" &= name "enablediagnostics" &= help "Enable diagnostic exceptions" }

startupStuff :: BoloArgs -> IO ()
startupStuff theArgs = do
  when (runServer theArgs) $ do
    delBoloTempFiles
    runServers' (boloServerArgs theArgs)
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
  -- if a template command file is not supplied, the hard-coded order insert example will be used and
  -- so we must run the related create table commands, etc.
  when (null cmdFile) $ do
    void $ runClientCommands (clientArgs theArgs) initialRequests
  batchCmds theArgs transactions True

batchCmds :: BoloArgs -> Int -> Bool -> IO Bool
batchCmds _ 0 allOk = return allOk -- all done
batchCmds theArgs@BoloArgs{..} totalRemaining allOk = do -- do next batch
  (sec, (ok, nDone, sz)) <- duration $ do
      let thisBatch = min totalRemaining batchSize
      let startNum = transactions - totalRemaining
      let batchReq = createMultiReq cmdFile startNum thisBatch
      putStrLn $ "batchCmds - multi-request created: "
            ++ "\n\r" ++ show batchReq
      _res <- runClientCommands (clientArgs theArgs) [batchReq]
      return (True, startNum+thisBatch, thisBatch) -- checkResults res
  batchCmds theArgs (totalRemaining-sz) (allOk && ok)

clientArgs :: BoloArgs -> [String]
clientArgs BoloArgs{..} = words $ "-c " ++ dirForConfig ++ configFile

boloDir :: String
boloDir = "executables/bolosim/"

boloServerArgs :: BoloArgs -> [String]
boloServerArgs theArgs = [boloServerArgs0 theArgs, boloServerArgs1 theArgs, boloServerArgs2 theArgs, boloServerArgs3 theArgs]

boloServerArgs0, boloServerArgs1, boloServerArgs2, boloServerArgs3 :: BoloArgs -> String
boloServerArgs0 a@BoloArgs{..} = "-c " ++ dirForConfig ++ "10000-cluster.yaml" ++ diagnostics a
boloServerArgs1 a@BoloArgs{..} = "-c " ++ dirForConfig ++ "10001-cluster.yaml" ++ diagnostics a
boloServerArgs2 a@BoloArgs{..} = "-c " ++ dirForConfig ++ "10002-cluster.yaml" ++ diagnostics a
boloServerArgs3 a@BoloArgs{..} = "-c " ++ dirForConfig ++ "10003-cluster.yaml" ++ diagnostics a

diagnostics :: BoloArgs -> String
diagnostics BoloArgs{..} =
  if enableDiagnostics then " --enableDiagnostics" else ""

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

createMultiReq :: FilePath -> Int -> Int -> TestRequest
createMultiReq cmdFile startNum numOrders =
  let theCmd = case cmdFile of
        [] -> "multiple " ++ show startNum ++ " " ++ show numOrders ++ " " ++ orderTemplate
        fp -> "loadMultiple " ++ show startNum ++ " " ++ show numOrders ++ " " ++ fp
  in TestRequest
       { cmd = theCmd
       , matchCmd = "TBD" -- MLN: need to find what the match str format is
       , eval = \_ -> return () -- not used in this sim
       , displayStr = "Creates an a request for multiple commands" }

orderTemplate :: String
orderTemplate =
    "(orders.create-order"
    ++ " " ++ esc "order-id-${count}"
    ++ " " ++ esc "some-keyset"
    ++ " " ++ esc "record-id-${count}"
    ++ " " ++ esc "hash-${count}"
    ++ " " ++ esc "npi-${count}"
    ++ " " ++ "(time " ++ esc "2015-01-01T00:00:00Z" ++ ")"
    ++ " " ++ esc "CHANNEL_${count}"
    ++ " " ++ esc "1234"
    ++ " " ++ esc "user-id-${count}"
    ++ " " ++ esc "Comment number ${count}"
    ++ " " ++ "(time " ++ esc "2018-01-01T00:00:00Z" ++ ")"
    ++ ")"
