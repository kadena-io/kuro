{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}

module ConfigChangeSpec (spec) where

import Control.Exception.Safe
import Control.Monad
import Data.Aeson as AE
import qualified Data.HashMap.Strict as HM
import Data.List.Extra
import Data.Scientific
import Safe
import System.Time.Extra
import Test.Hspec

import Apps.Kadena.Client
import Kadena.Types.Command hiding (result)
import Pact.Types.API

import Util.TestRunner

spec :: Spec
spec = do
    describe "testClusterCommands" testClusterCommands

testClusterCommands :: Spec
testClusterCommands =
        it "tests commands send to a locally running cluster" $ do
            delTempFiles
            runServers
            putStrLn "Servers are running, sleeping for a few seconds"
            _ <- sleep 3
            catchAny (do
                         putStrLn "\nCommand tests:"
                         results <- runClientCommands clientArgs testRequests
                         checkResults results

                         putStrLn "\nMetric test - waiting for cluster size == 4..."
                         okSize4 <- waitForMetric testMetricSize4
                         okSize4 `shouldBe` True

                         --checking for the right list of cluster members
                         m123 <- gatherMetrics [testMetric123]
                         okM123 <- checkMetrics m123
                         okM123 `shouldBe` True

                         putStrLn "\nConfig change test #1 - Dropping node02:"
                         ccResults1 <- runClientCommands clientArgs ccTest0123to013
                         checkResults ccResults1

                         putStrLn "Metric test - waiting for cluster size == 3..."
                         okSize3 <- waitForMetric testMetricSize3
                         okSize3 `shouldBe` True

                         --checking for the right list of cluster members
                         m13 <- gatherMetrics [testMetric13]
                         okM13 <- checkMetrics m13
                         okM13 `shouldBe` True

                         putStrLn "Runing post config change #1 commands:"
                         results2 <- runClientCommands clientArgs testRequestsRepeated
                         checkResults results2

                         {-
                         putStrLn "Config change test#2 - adding back node02:"
                         ccResults1b <- runClientCommands clientArgs ccTest013to0123
                         checkResults ccResults1b
                         -}

                         putStrLn "Config change test #2 - Dropping node3, adding node2"
                         ccResults2 <- runClientCommands clientArgs ccTest013to012
                         checkResults ccResults2

                         putStrLn "Metric test - waiting for the set {node0, node1, node2}..."
                         ok012 <- waitForMetric testMetric12
                         ok012 `shouldBe` True

                         putStrLn "Runing post config change #2 commands:"
                         results3 <- runClientCommands clientArgs testRequestsRepeated
                         checkResults results3

                         putStrLn "Done.")
                     (\e -> throw e)

clientArgs :: [String]
clientArgs = words $ "-c " ++ testConfDir ++ "client.yaml"

checkResults :: [TestResult] -> Expectation
checkResults xs = mapM_ checkResult xs
    --foldr checkResult (return True) (reverse xs)
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

checkMetrics :: [TestMetricResult] -> IO Bool
checkMetrics xs =
    foldr checkMetric (return True) xs where
        checkMetric result ok = do
            let req = requestTmr result
            let valueStr = valueTmr result
            bOk <- ok
            case valueStr of
                Nothing -> do
                    failMetric result "Metric is missing"
                    return False
                Just val -> do
                    let r = evalTm req val
                    if not r
                      then return False
                      else do
                        passMetric result
                        return $ r && bOk

checkSuccess :: TestResponse -> Expectation
checkSuccess tr = do
  resultSuccess tr `shouldBe` True
  --parseStatus (_arResult $ apiResult tr)

checkCCSuccess :: TestResponse -> Expectation
checkCCSuccess tr = do
  resultSuccess tr `shouldBe` True
  parseCCStatus (_arResult $ apiResult tr) `shouldBe` True

checkScientific :: Scientific -> TestResponse -> Expectation
checkScientific sci tr = do
  resultSuccess tr `shouldBe` True
  parseScientific (_arResult $ apiResult tr) `shouldBe` Just sci

checkBatchPerSecond :: Integer -> TestResponse -> Expectation
checkBatchPerSecond minPerSec tr = do
    resultSuccess tr `shouldBe` True
    perSecMay tr `shouldSatisfy` check
  where
    check (Just perSec) = perSec >= minPerSec
    check Nothing = False

perSecMay :: TestResponse -> Maybe Integer
perSecMay tr = do
    count <- _batchCount tr
    (AE.Success lats) <- fromJSON <$> (_arMetaData (apiResult tr))
    microSeconds <- _rlmFinExecution lats
    return $ snd $ calcInterval count microSeconds

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

failMetric :: TestMetricResult -> String -> IO ()
failMetric tmr addlInfo = do
    putStrLn $ "Metric failure: " ++ metricNameTm (requestTmr tmr)
    putStrLn $ "Value received: " ++ show (valueTmr tmr)
    putStrLn $ "(" ++ addlInfo ++ ")"

passMetric :: TestMetricResult -> IO ()
passMetric tmr = putStrLn $ "Metric test passed: " ++ metricNameTm (requestTmr tmr)

testRequests :: [TestRequest]
--testRequests = [testReq1, testReq2, testReq3, testReq4, testReq5]
testRequests = [testReq1, testReq2, testReq3, testReq4]

_ccTestRequests0 :: [TestRequest]
_ccTestRequests0 = [_testCfgChange0]

ccTest0123to013 :: [TestRequest]
ccTest0123to013 = [cfg0123to013]

ccTest013to0123 :: [TestRequest]
ccTest013to0123 = [cfg013to0123]

ccTest013to012:: [TestRequest]
ccTest013to012 = [cfg013to012]

-- tests that can be repeated
testRequestsRepeated :: [TestRequest]
-- testRequestsRepeated = [testReq1, testReq4, testReq5]
testRequestsRepeated = [testReq1, testReq4]

testReq1 :: TestRequest
testReq1 = TestRequest
  { cmd = "exec (+ 1 1)"
  , matchCmd = "exec (+ 1 1)"
  , eval = (\tr -> checkScientific (scientific 2 0) tr)
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
  { cmd = "batch 4000"
  , matchCmd = "(test.transfer \"Acct1\" \"Acct2\" 1.00)"
  , eval = checkBatchPerSecond 1000
  , displayStr = "Executes the function transferring 1.00 from Acct 1 to Acc2 4000 times" }

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

testMetricSize4 :: TestMetric
testMetricSize4 = TestMetric
  { metricNameTm = "/kadena/cluster/size"
  , evalTm = (\s -> readDef (0.0 :: Float) s == 4.0) }

testMetricSize3 :: TestMetric
testMetricSize3 = TestMetric
  { metricNameTm = "/kadena/cluster/size"
  , evalTm = (\s -> readDef (0.0 :: Float) s == 3.0) }

testMetric123 :: TestMetric
testMetric123 = TestMetric
  { metricNameTm = "/kadena/cluster/members"
  , evalTm = (\s -> (splitOn ", " s) /= ["node1", "node2", "node3"]) }

testMetric13 :: TestMetric
testMetric13 = TestMetric
  { metricNameTm = "/kadena/cluster/members"
  , evalTm = (\s -> (splitOn ", " s) /= ["node1", "node3"]) }

testMetric12 :: TestMetric
testMetric12 = TestMetric
  { metricNameTm = "/kadena/cluster/members"
  , evalTm = (\s -> (splitOn ", " s) /= ["node1", "node2"]) }





waitForMetric :: TestMetric -> IO Bool
waitForMetric tm = do
  t <- timeout 10 go
  return $ case t of
    Nothing -> False
    Just _ -> True
  where
    go :: IO ()
    go = do
      rs <- gatherMetrics [tm]
      ok <- checkMetrics rs
      unless ok go
      return ()
