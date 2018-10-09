{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -fno-cse #-}

module Main
  ( main
  ) where

import Control.Monad
import Data.Either
import Data.List.Extra
import Data.Maybe
import Safe
import System.Command
import System.Console.CmdArgs
import System.Time.Extra

import Apps.Kadena.Client (esc)
import Util.TestRunner

main :: IO ()
main = do
  theArgs <- cmdArgs insertArgs
  startupStuff theArgs
  ok <- runWithBatch theArgs
  if ok then putStrLn "Run succeeded." else putStrLn "Run failed."

data BatchType = InsertOrders | CreateAcct | AcctTransfer | AcctTransferUnique
  deriving (Data, Show)

data InsertArgs = InsertArgs
  { transactions :: Int
  , batchSize :: Int
  , batchType  :: BatchType
  , noRunServer :: Bool
  , configFile :: String
  , dirForConfig :: String
  , enableDiagnostics :: Bool }
  deriving (Show, Data, Typeable)

insertArgs :: InsertArgs
insertArgs = InsertArgs
  { transactions = 120000 &= name "t" &= help "Number of transactions to run"
  , batchSize = 3000 &= name "b" &= name "batchsize" &= help "Number of transactions in each batch"
  , batchType = enum
    [ InsertOrders &= help "Insert multiple orders" &= name "insertorders" &= name "io"
    , CreateAcct &= help "Create multiple accounts" &= name "createacct" &= name "ca"
    , AcctTransfer &= help "Execute multiple acct transfers" &= name "accttransfer" &= name "at"
    , AcctTransferUnique &= help "Execute multiple acct transfers with unique transfer amounts"
      &= name "accttransferunique" &= name "atu" ]
  , noRunServer = False &= name "n" &= name "norunserver" &= help "Flag specifying this exe should not launch Kadena server instances"
  , configFile = "client.yaml" &= name "c" &= name "configfile" &= help "Kadena config file"
  , dirForConfig = "executables/inserts/conf/" &= name "d" &= name "dirForConfig" &= help "Location of config files"
  , enableDiagnostics = False &= name "e" &= name "enablediagnostics" &= help "Enable diagnostic exceptions" }

startupStuff :: InsertArgs -> IO ()
startupStuff theArgs = do
  when (runServer theArgs) $ do
    delInsertsTempFiles
    runServers' (insertsServerArgs theArgs)
    putStrLn $ "Waiting for confirmation that cluster size == 4..."
    _ <- waitForMetric testMetricSize4
    return ()
  return ()

-- clean up the double-negative -- since 'noRunServer' makes the most sense as an option ...
runServer :: InsertArgs -> Bool
runServer InsertArgs{..} = not noRunServer

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

delInsertsTempFiles :: IO ()
delInsertsTempFiles = do
   let p = shell $ insertsDir ++ "deleteFiles.sh"
   _ <- createProcess p
   return ()

runWithBatch :: InsertArgs -> IO Bool
runWithBatch theArgs@InsertArgs{..} = do
  putStrLn $ "Running " ++ show transactions ++ " transactions in batches of " ++ show batchSize
  -- required create table, etc. commands for the repeated batch commands
  void $ runClientCommands (clientArgs theArgs) (getInitialRequests theArgs)
  batchCmds theArgs transactions True

batchCmds :: InsertArgs -> Int -> Bool -> IO Bool
batchCmds _ 0 allOk = return allOk -- all done
batchCmds theArgs@InsertArgs{..} totalRemaining allOk = do -- do next batch
  (_sec, (ok, _nDone, sz)) <- duration $ do
      let thisBatch = min totalRemaining batchSize
      let startNum = transactions - totalRemaining
      let batchReq = createMultiReq batchType startNum thisBatch
      putStrLn $ "batchCmds - multi-request created: "
            ++ "\n\r" ++ show batchReq
      _res <- runClientCommands (clientArgs theArgs) [batchReq]
      return (True, startNum+thisBatch, thisBatch) -- checkResults res
  batchCmds theArgs (totalRemaining-sz) (allOk && ok)

clientArgs :: InsertArgs -> [String]
clientArgs a@InsertArgs{..} = words $ "-c " ++ getDirForConfig a ++ configFile

insertsDir :: String
insertsDir = "executables/inserts/"

insertsServerArgs :: InsertArgs -> [String]
insertsServerArgs theArgs = [ insertsServerArgs0 theArgs, insertsServerArgs1 theArgs
                            , insertsServerArgs2 theArgs, insertsServerArgs3 theArgs]

insertsServerArgs0, insertsServerArgs1, insertsServerArgs2, insertsServerArgs3 :: InsertArgs -> String
insertsServerArgs0 a@InsertArgs{..} = "-c " ++ getDirForConfig a ++ "10000-cluster.yaml" ++ diagnostics a
insertsServerArgs1 a@InsertArgs{..} = "-c " ++ getDirForConfig a ++ "10001-cluster.yaml" ++ diagnostics a
insertsServerArgs2 a@InsertArgs{..} = "-c " ++ getDirForConfig a ++ "10002-cluster.yaml" ++ diagnostics a
insertsServerArgs3 a@InsertArgs{..} = "-c " ++ getDirForConfig a ++ "10003-cluster.yaml" ++ diagnostics a

diagnostics :: InsertArgs -> String
diagnostics InsertArgs{..} =
  if enableDiagnostics then " --enableDiagnostics" else ""

getDirForConfig :: InsertArgs -> String
getDirForConfig a =
  let orig = dirForConfig a
  in (dropSuffix' "/" orig)  ++ "/" -- ensure always one '/' at the end

-- this can be replaced with dropSuffix from Data.List.Extra when we upgrade the versions of
-- external libraries
dropSuffix' :: Eq a => [a] -> [a] -> [a]
dropSuffix' a b = fromMaybe b $ stripSuffix a b

getInitialRequests :: InsertArgs -> [TestRequest]
getInitialRequests (batchType -> CreateAcct) = createAcctsInitReqs
getInitialRequests (batchType -> AcctTransfer) = acctTransferInitReqs
getInitialRequests (batchType -> AcctTransferUnique) = acctTransferInitReqs
getInitialRequests (batchType -> _) = insertOrdersInitReqs -- InsertOrders is the default

insertOrdersInitReqs :: [TestRequest]
insertOrdersInitReqs = [loadOrders]

createAcctsInitReqs :: [TestRequest]
createAcctsInitReqs = [loadDemo]

acctTransferInitReqs :: [TestRequest]
acctTransferInitReqs = [loadDemo, createGlobalAccts]

loadDemo :: TestRequest
loadDemo = TestRequest
  { cmd = "load demo/demo.yaml"
  , matchCmd = "demo/demo.yaml"
  , eval = printEval
  , displayStr = "Loads the demo yaml file." }

loadOrders :: TestRequest
loadOrders = TestRequest
  { cmd = "load demo/orders.yaml"
  , matchCmd = "demo/orders.yaml"
  , eval = printEval
  , displayStr = "Loads the orders yaml file." }

createGlobalAccts :: TestRequest
createGlobalAccts = TestRequest
  { cmd = "exec (demo.create-global-accounts)"
  , matchCmd = "exec (demo.create-global-accounts)"
  , eval = printEval
  , displayStr = "Creates the global accounts" }

printEval :: TestResponse -> IO ()
printEval tr = if resultSuccess tr then return () else putStrLn $ "Evaluation failed"

_testReq :: TestRequest
_testReq = TestRequest
  { cmd = "exec (+ 1 1)"
  , matchCmd = "exec (+ 1 1)"
  , eval = \_ -> return () -- not used in this sim
  , displayStr = "Executes 1 + 1 in Pact" }

createMultiReq :: BatchType -> Int -> Int -> TestRequest
createMultiReq batchType startNum numOrders =
  let theTemplate = case batchType of
        CreateAcct -> createAcctTemplate
        AcctTransfer -> acctTransferTemplate
        AcctTransferUnique -> acctTransferUniqueTemplate
        _ -> insertOrderTemplate -- InsertOrders is the default
      theCmd = "multiple " ++ show startNum ++ " " ++ show numOrders ++ " " ++ theTemplate
  in TestRequest
       { cmd = theCmd
       , matchCmd = "TBD" -- MLN: need to find what the match str format is
       , eval = \_ -> return () -- not used in this sim
       , displayStr = "Creates an a request for multiple commands" }

insertOrderTemplate :: String
insertOrderTemplate =
    "(orders.create-order"
    ++ " " ++ esc "order-id-${count}"
    ++ " " ++ esc "some-keyset"
    ++ " " ++ esc "record-id-${count}"
    ++ " " ++ esc "hash-${count}"
    ++ " " ++ "(time " ++ esc "2015-01-01T00:00:00Z" ++ ")"
    ++ " " ++ esc "user-id-${count}"
    ++ " " ++ esc "Comment number ${count}"
    ++ " " ++ "(time " ++ esc "2018-01-01T00:00:00Z" ++ ")"
    ++ ")"

createAcctTemplate :: String
createAcctTemplate =
    "(demo.create-account"
    ++ " " ++ esc "Acct${count}"
    ++ " " ++ "100000${count}.0"
    ++ ")"

acctTransferTemplate :: String
acctTransferTemplate =
    "(demo.transfer"
    ++ " " ++ esc "Acct1"
    ++ " " ++ esc "Acct2"
    ++ " " ++ "1.0"
    ++ ")"

acctTransferUniqueTemplate :: String
acctTransferUniqueTemplate =
    "(demo.transfer"
    ++ " " ++ esc "Acct1"
    ++ " " ++ esc "Acct2"
    ++ " " ++ "0.${count}"
    ++ ")"
