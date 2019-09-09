{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module ConfigChangeSpec (spec) where

import           Control.Monad
import           Data.Aeson as AE
import           Data.Either
import qualified Data.HashMap.Strict as HM
import           Data.List.Extra
import           Data.Maybe
import           Data.Scientific
import           Safe
import           System.Time.Extra (sleep)
import           Test.Hspec

import           Apps.Kadena.Client
import           Kadena.Types.Command hiding (result)

import           Util.TestRunner

startupStuff :: IO ()
startupStuff = do
  delTempFiles
  runServers

spec :: Spec
spec = do
  startupStuff `beforeAll_` describe "testClusterCommands" testClusterCommands

testClusterCommands :: Spec
testClusterCommands = do

----------------------------------------------------------------------------------------------------
-- Tests that work in Pact (3.0 / 3.1)
----------------------------------------------------------------------------------------------------
  it "passes command tests" $ do
    results <- runClientCommands clientArgs testRequests
    checkResults results

  it "Metric test - waiting for cluster size == 4..." $ do
    okSize4 <- waitForMetric testMetricSize4
    okSize4 `shouldBe` True

  --checking for the right list of cluster members
  it "gathering metrics for testMetric123" $ do
    m123 <- gatherMetric testMetric123
    assertEither $ getMetricResult m123

----------------------------------------------------------------------------------------------------
-- Current test being debugged (Pact 3.0 / 3.1)
----------------------------------------------------------------------------------------------------
  xit "Config change test #1 - Dropping node02:" $ do
    ccResults1 <- runClientCommands clientArgs [cfg0123to013]
    checkResults ccResults1

----------------------------------------------------------------------------------------------------
-- Tests not yet re-enabled (Pact 3.0 / 3.1)
----------------------------------------------------------------------------------------------------
  xit "Metric test - waiting for cluster size == 3..." $ do
    okSize3 <- waitForMetric testMetricSize3
    okSize3 `shouldBe` True

  --checking for the right list of cluster members
  xit "gathering metrics for testMetric13" $ do
    m13 <- gatherMetric testMetric13
    assertEither $ getMetricResult m13

  xit "Runing post config change #1 commands:" $ do
    sleep 3
    results1b <- runClientCommands clientArgs testRequestsRepeated
    checkResults results1b

  xit "Config change test #2 - Dropping node3, adding node2" $ do
    sleep 3
    ccResults2 <- runClientCommands clientArgs [cfg013to012]
    checkResults ccResults2

  xit "Metric test - waiting for the set {node0, node1, node2}..." $ do
    ok012 <- waitForMetric testMetric12
    ok012 `shouldBe` True

  xit "Runing post config change #2 commands:" $ do
    sleep 3
    results2b <- runClientCommands clientArgs testRequestsRepeated
    checkResults results2b

  xit "Config change test #3 - adding back node3" $ do
    sleep 3
    ccResults3 <- runClientCommands clientArgs [cfg012to0123]
    checkResults ccResults3

  xit "Metric test - waiting for cluster size == 4..." $ do
    okSize4b <- waitForMetric testMetricSize4
    okSize4b `shouldBe` True

  xit "Runing post config change #3 commands:" $ do
    sleep 3
    results3b <- runClientCommands clientArgs testRequestsRepeated
    checkResults results3b

  xit "Changes the current server to node1:" $ do
    resultsNode1 <- runClientCommands clientArgs [serverCmd 1]
    checkResults resultsNode1

  xit "Runs test commands from node1:" $ do
    results3c <- runClientCommands clientArgs testRequestsRepeated
    checkResults results3c

  xit "Config change test #4 - dropping the leader (node0)" $ do
    sleep 3
    ccResults4 <- runClientCommands clientArgs [cfg0123to123]
    checkResults ccResults4

  xit "Metric test - waiting for cluster size == 3..." $ do
    okSize3b <- waitForMetric' testMetricSize3 1 -- cant use node0 for the metrics now...
    okSize3b `shouldBe` True

  xit "Runing post config change #4 commands:" $ do
    sleep 3
    results4b <- runClientCommands clientArgs testRequestsRepeated
    checkResults results4b

clientArgs :: [String]
clientArgs = words $ "-c " ++ testConfDir ++ "client.yaml"

checkResults :: [TestResult] -> Expectation
checkResults xs = mapM_ checkResult xs
  where
    checkResult result = do
        let req = requestTr result
        let resp = responseTr result
        case resp of
          Nothing -> expectationFailure $
            failureMessage result "Response is missing"
          Just rsp -> do
            printPassed result
            eval req rsp

assertEither :: Either String String -> Expectation
assertEither (Left e) = expectationFailure e
assertEither (Right msg) = putStrLn msg

assertMetricResult :: TestMetricResult -> Spec
assertMetricResult tmr =
    it (metricNameTm $ requestTmr tmr) $ assertEither $ getMetricResult tmr

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

checkSuccess :: TestResponse -> Expectation
checkSuccess tr = do
  resultSuccess tr `shouldBe` True

checkCCSuccess :: TestResponse -> Expectation
checkCCSuccess tr = do
  resultSuccess tr `shouldBe` True

checkBatchPerSecond :: Integer -> TestResponse -> Expectation
checkBatchPerSecond minPerSec tr = do
    resultSuccess tr `shouldBe` True
    perSecMay tr `shouldSatisfy` check
  where
    check (Just perSec) = perSec >= minPerSec
    check Nothing = False

perSecMay :: TestResponse -> Maybe Integer
perSecMay tr = do
    let cnt = _batchCount tr
    if cnt == 1 then Nothing
    else do
      let res = apiResult tr
      case _crLatMetrics res of
          Nothing -> Nothing
          Just lats -> do
            microSeconds <- _rlmFinExecution lats
            return $ snd $ calcInterval cnt microSeconds

parseCCStatus :: AE.Value -> Bool
parseCCStatus (AE.Object o) =
  case HM.lookup "tag" o of
    Nothing -> False
    Just s -> s == "ClusterChangeSuccess"
parseCCStatus _ = False

parseScientific :: AE.Value -> Maybe Scientific
parseScientific (AE.Object o) =
  case HM.lookup "data" o of
    Nothing -> Nothing
    Just (AE.Number sci) -> Just sci
    Just _ -> Nothing
parseScientific _ = Nothing

failureMessage :: TestResult -> String -> String
failureMessage tr addlInfo = unlines
    [ "Test failure: " ++ cmd (requestTr tr)
    , "(" ++ addlInfo ++ ")"
    ]

printPassed :: TestResult -> IO ()
printPassed tr = putStrLn $ "Test passed: " ++ cmd (requestTr tr)

failMetric :: TestMetricResult -> String -> String
failMetric tmr addlInfo = unlines
    [ "Metric failure: " ++ metricNameTm (requestTmr tmr)
    , "Value received: " ++ show (valueTmr tmr)
    , "(" ++ addlInfo ++ ")"
    ]

passMetric :: TestMetricResult -> String
passMetric tmr = "Metric test passed: " ++ metricNameTm (requestTmr tmr)

testRequests :: [TestRequest]
testRequests = [testReq1, testReq2, testReq3, testReq4, testReq5, testReq6]

testRequestsRepeated :: [TestRequest]
testRequestsRepeated = [testReq1, testReq4, testReq5, testReq6]

testReq1 :: TestRequest
testReq1 = TestRequest
  { cmd = "exec (+ 1 1)"
  , matchCmd = "exec (+ 1 1)"
  , eval = checkSuccess
  , displayStr = "Executes 1 + 1 in Pact and returns 2.0" }

testReq2 :: TestRequest
testReq2 = TestRequest
  { cmd = "load test-files/test.yaml"
  , matchCmd = "test-files/test.yaml"
  , eval = checkSuccess
  , displayStr = "Loads the Pact configuration file test.yaml" }

testReq3 :: TestRequest
testReq3 = TestRequest
  { cmd = "exec (test.create-global-accounts)"
  , matchCmd = "exec (test.create-global-accounts)"
  , eval = checkSuccess
  , displayStr = "Executes the create-global-accounts Pact function" }

testReq4 :: TestRequest
testReq4 = TestRequest
  { cmd = "exec (test.transfer \"Acct1\" \"Acct2\" 1.00)"
  , matchCmd = "exec (test.transfer \"Acct1\" \"Acct2\" 1.00)"
  , eval = checkSuccess
  , displayStr = "Executes a Pact function transferring 1.00 from Acct1 to Acct2" }

testReq5 :: TestRequest
testReq5 = TestRequest
  { cmd = "batch 100"
  , matchCmd = "(test.transfer \"Acct1\" \"Acct2\" 1.00)"
  -- , eval = checkBatchPerSecond 25
  , eval = checkSuccess
  , displayStr = "Executes the function transferring 1.00 from Acct 1 to Acc2 100 times" }

testReq6 :: TestRequest
testReq6 = TestRequest
  { cmd = "exec (list-modules)"
  , matchCmd = "exec (list-modules)"
  , eval = checkSuccess
  , displayStr = "Executes the Pact build-in function list-modules" }

_testCfgChange0 :: TestRequest
_testCfgChange0 = TestRequest
  { cmd = "configChange test-files/conf/config-change-00.yaml"
  , matchCmd = "test-files/conf/config-change-00.yaml"
  , eval = checkCCSuccess
  , displayStr = "Removes node2 from the cluster" }

cfg0123to013 :: TestRequest
cfg0123to013 = TestRequest
  { cmd = "configChange test-files/conf/config-change-01.yaml"
  , matchCmd = "test-files/conf/config-change-01.yaml"
  , eval = checkCCSuccess
  , displayStr = "Removes node2 from the cluster" }

cfg0123to123 :: TestRequest
cfg0123to123 = TestRequest
  { cmd = "configChange test-files/conf/config-change-04.yaml"
  , matchCmd = "test-files/conf/config-change-04.yaml"
  , eval = checkCCSuccess
  , displayStr = "Removes the leader (node0) from the cluster" }

cfg013to0123 :: TestRequest
cfg013to0123 = TestRequest
  { cmd = "configChange test-files/conf/config-change-01b.yaml"
  , matchCmd = "test-files/conf/config-change-01b.yaml"
  , eval = checkCCSuccess
  , displayStr = "Replaces node2 back into the cluster" }

cfg013to012 :: TestRequest
cfg013to012 = TestRequest
  { cmd = "configChange test-files/conf/config-change-02.yaml"
  , matchCmd = "test-files/conf/config-change-02.yaml"
  , eval = checkCCSuccess
  , displayStr = "Adds back node2 and removes node3 from the cluster" }

cfg012to0123 :: TestRequest
cfg012to0123 = TestRequest
  { cmd = "configChange test-files/conf/config-change-03.yaml"
  , matchCmd = "test-files/conf/config-change-03.yaml"
  , eval = checkCCSuccess
  , displayStr = "Replaces node3 back into the cluster" }

serverCmd :: Int -> TestRequest
serverCmd n =
  TestRequest
  { cmd = "server node" ++ show n
  , matchCmd = "server node" ++ show n
  , eval = checkSuccess
  , displayStr = "Changes the current server that accepts commands" }

testMetricSize4 :: TestMetric
testMetricSize4 = TestMetric
  { testNameTm = "testMetricSize4"
  , metricNameTm = "/kadena/cluster/size"
  , evalTm = (\s -> readDef (0.0 :: Float) s == 4.0) }

testMetricSize3 :: TestMetric
testMetricSize3 = TestMetric
  { testNameTm = "testMetricSize3"
  , metricNameTm = "/kadena/cluster/size"
  , evalTm = (\s -> readDef (0.0 :: Float) s == 3.0) }

testMetric123 :: TestMetric
testMetric123 = TestMetric
  { testNameTm = "testMetric123"
  , metricNameTm = "/kadena/cluster/members"
  , evalTm = (\s -> (splitOn ", " s) /= ["node1", "node2", "node3"]) }

testMetric13 :: TestMetric
testMetric13 = TestMetric
  { testNameTm = "testMetric13"
  , metricNameTm = "/kadena/cluster/members"
  , evalTm = (\s -> (splitOn ", " s) /= ["node1", "node3"]) }

testMetric12 :: TestMetric
testMetric12 = TestMetric
  { testNameTm = "testMetric12"
  , metricNameTm = "/kadena/cluster/members"
  , evalTm = (\s -> (splitOn ", " s) /= ["node1", "node2"]) }

-- | Adding `sleep` between failures prevents the metrics server
-- from being hammered.
waitForMetric :: TestMetric -> IO Bool
waitForMetric tm = waitForMetric' tm 0

-- Version of waitForMetric that takes node number (0-3) as additional param
waitForMetric' :: TestMetric -> Int -> IO Bool
waitForMetric' tm node =
  isJust <$> timeout 30 go
  where
    go :: IO ()
    go = do
      res <- gatherMetric' tm node
      let z = getMetricResult res
      when (isLeft z) $ do
        sleep 1
        go
