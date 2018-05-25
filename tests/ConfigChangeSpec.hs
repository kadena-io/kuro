{-# LANGUAGE OverloadedStrings #-}

module ConfigChangeSpec (spec) where

import Data.Aeson as AE
import qualified Data.HashMap.Strict as HM
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Scientific
import Data.Set (Set)
import qualified Data.Set as Set
import Safe
import Test.Hspec

import Apps.Kadena.Client
import Kadena.Evidence.Service (checkPartialEvidence')
import Kadena.Types.Base (Alias (..), LogIndex(..), NodeId(..))
import Kadena.Types.Command hiding (result)
import Pact.Types.API

import Util.TestRunner

spec :: Spec
spec = do
    describe "checkPartialEvidence'" $
        it "sums exisiting votes according to their commit indexes" $ do
            b <- testPartialEvidence
            b `shouldBe` True
    describe "testClusterCommands" $
        it "tests commands send to a locally running cluster" $ do
            delTempFiles
            (results, metrics) <- runAll testRequests testMetrics
            putStrLn "\nCommand tests:"
            ok <- checkResults results
            ok `shouldBe` True
            putStrLn "\nMetric tests:"
            metricsOk <- checkMetrics metrics
            metricsOk `shouldBe` True

testPartialEvidence :: IO Bool
testPartialEvidence = do
  let mResults =
        mapM f partialEvTests where
          f :: (TestPartialEv, Either [Int] LogIndex) -> IO Bool
          f (t, expected) = do
            let r = checkPartialEvidence' (tNodeIds t) (tChgToNodeIds t) (tEvNeeded t) (tChgToEvNeeded t) (tPartialEv t)
            case (r, expected) of
              (Left lR, Left lExpected) ->
                if lR == lExpected
                  then return True
                  else do
                    putStrLn $ "Lefts dont match for test: " ++ tName t
                    putStrLn $ "Expected: " ++ show lExpected ++ " but got: " ++ show lR
                    return False
              (Right rR, Right rExpected) ->
                if rR == rExpected
                  then return True
                  else do
                    putStrLn $ "Rights dont match for test: " ++ tName t
                    putStrLn $ "Expected: " ++ show rExpected ++ " but got: " ++ show rR
                    return False
              (x, y) -> do
                putStrLn $ "Left/right mismatch for test: " ++ tName t
                putStrLn $ "Expected: " ++ show x ++ " but got: " ++ show y
                return False
  bools <- mResults
  return $ and bools

data TestPartialEv = TestPartialEv
  { tName :: String
  , tNodeIds :: Set NodeId
  , tChgToNodeIds :: Set NodeId
  , tEvNeeded :: Int
  , tChgToEvNeeded :: Int
  , tPartialEv :: Map LogIndex (Set NodeId) }

partialEvTests :: [(TestPartialEv, Either [Int] LogIndex)]
partialEvTests =
  [ (TestPartialEv
      { tName = "test1"
      , tNodeIds = nodeIdSet123
      , tChgToNodeIds = Set.empty
      , tEvNeeded = 3
      , tChgToEvNeeded = 0
      , tPartialEv = logToNodesMapA}, Right (LogIndex 2))
  , (TestPartialEv
      { tName = "test2"
      , tNodeIds = nodeIdSet123
      , tChgToNodeIds = nodeIdSet2345
      , tEvNeeded = 3
      , tChgToEvNeeded = 4
      , tPartialEv = logToNodesMapB}, Right (LogIndex 2))
  , (TestPartialEv
      { tName = "test3"
      , tNodeIds = nodeIdSet2345
      , tChgToNodeIds = Set.empty
      , tEvNeeded = 4
      , tChgToEvNeeded = 0
      , tPartialEv = logToNodesMapC}, Right (LogIndex 1))
  , (TestPartialEv
      { tName = "test4"
      , tNodeIds = nodeIdSet123
      , tChgToNodeIds = nodeIdSet2345
      , tEvNeeded = 3
      , tChgToEvNeeded = 4
      , tPartialEv = logToNodesMapD}, Left [0, 2])
  ]

logToNodesMapA, logToNodesMapB, logToNodesMapC, logToNodesMapD :: Map LogIndex (Set NodeId)
logToNodesMapA = Map.fromList
  [ (LogIndex 1, nodeIdSet0)
  , (LogIndex 2, nodeIdSet12)
  , (LogIndex 3, nodeIdSet3) ]
logToNodesMapB = Map.fromList
  [ (LogIndex 1, nodeIdSet0)
  , (LogIndex 2, nodeIdSet1)
  , (LogIndex 3, nodeIdSet2345) ]
logToNodesMapC = Map.fromList
  [ (LogIndex 1, nodeIdSet45)
  , (LogIndex 2, nodeIdSet12)
  , (LogIndex 3, nodeIdSet3) ]
logToNodesMapD = Map.fromList
  [ (LogIndex 1, nodeIdSet0)
  , (LogIndex 2, nodeIdSet12)
  , (LogIndex 3, nodeIdSet3) ]

nodeIdSet123, nodeIdSet2345, nodeIdSet45, nodeIdSet12, nodeIdSet3, nodeIdSet1, nodeIdSet0 :: Set NodeId
nodeIdSet123 = Set.fromList [nodeId1, nodeId2, nodeId3]
nodeIdSet2345 = Set.fromList [nodeId2, nodeId3, nodeId4, nodeId5]
nodeIdSet45 = Set.fromList [nodeId4, nodeId5]
nodeIdSet12 = Set.fromList [nodeId1, nodeId2]
nodeIdSet1 = Set.fromList [nodeId1]
nodeIdSet3 = Set.fromList [nodeId3]
nodeIdSet0 = Set.fromList [nodeId0]

nodeId0, nodeId1, nodeId2, nodeId3, nodeId4, nodeId5 :: NodeId
nodeId0 = NodeId { _host = "host0", _port = 1000, _fullAddr = "fullAddr0", _alias = Alias {unAlias = "alias0"} }
nodeId1 = NodeId { _host = "host1", _port = 1001, _fullAddr = "fullAddr1", _alias = Alias {unAlias = "alias1"} }
nodeId2 = NodeId { _host = "host2", _port = 1002, _fullAddr = "fullAddr2", _alias = Alias {unAlias = "alias2"} }
nodeId3 = NodeId { _host = "host3", _port = 1003, _fullAddr = "fullAddr3", _alias = Alias {unAlias = "alias3"} }
nodeId4 = NodeId { _host = "host4", _port = 1004, _fullAddr = "fullAddr4", _alias = Alias {unAlias = "alias4"} }
nodeId5 = NodeId { _host = "host5", _port = 1005, _fullAddr = "fullAddr5", _alias = Alias {unAlias = "alias5"} }

checkResults :: [TestResult] -> IO Bool
checkResults xs =
    foldr checkResult (return True) (reverse xs) where
        checkResult result ok = do
            let req = requestTr result
            let resp = responseTr result
            bOk <- ok
            case resp of
                Nothing -> do
                    failTest result "Response is missing"
                    return False
                Just rsp -> do
                    let r = eval req rsp
                    if not r
                      then do
                        failTest result "Eval function failed"
                        return False
                      else do
                        passTest result
                        return $ r && bOk

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
                      then do
                        failMetric result "Metric Eval function failed"
                        return False
                      else do
                        passMetric result
                        return $ r && bOk

checkSuccess :: TestResponse -> Bool
checkSuccess tr =
  resultSuccess tr && parseStatus (_arResult $ apiResult tr)

checkScientific :: Scientific -> TestResponse -> Bool
checkScientific sci tr =
  resultSuccess tr && case parseScientific $ _arResult $ apiResult tr of
    Nothing -> False
    Just x  -> x == sci

checkBatchPerSecond :: Integer -> TestResponse -> Bool
checkBatchPerSecond minPerSec tr =
  let perSecOk = case perSecMay tr of
        Nothing -> False
        Just perSec -> perSec >= minPerSec
  in resultSuccess tr && perSecOk

perSecMay :: TestResponse -> Maybe Integer
perSecMay tr = do
    count <- _batchCount tr
    (AE.Success lats) <- fromJSON <$> (_arMetaData (apiResult tr))
    microSeconds <- _rlmFinExecution lats
    return $ snd $ calcInterval count microSeconds

parseStatus :: AE.Value -> Bool
parseStatus (AE.Object o) =
  case HM.lookup "status" o of
    Nothing -> False
    Just s  -> s == "success"
parseStatus _ = False

parseScientific :: AE.Value -> Maybe Scientific
parseScientific (AE.Object o) =
  case HM.lookup "data" o of
    Nothing -> Nothing
    Just (AE.Number sci) -> Just sci
    Just _ -> Nothing
parseScientific _ = Nothing

failTest :: TestResult -> String -> IO ()
failTest tr addlInfo = do
    putStrLn $ "Test failure: " ++ cmd (requestTr tr)
    putStrLn $ "(" ++ addlInfo ++ ")"

passTest :: TestResult -> IO ()
passTest tr = putStrLn $ "Test passed: " ++ cmd (requestTr tr)

failMetric :: TestMetricResult -> String -> IO ()
failMetric tmr addlInfo = do
    putStrLn $ "Metric failure: " ++ metricNameTm (requestTmr tmr)
    putStrLn $ "(" ++ addlInfo ++ ")"

passMetric :: TestMetricResult -> IO ()
passMetric tmr = putStrLn $ "Metric test passed: " ++ metricNameTm (requestTmr tmr)

testRequests :: [TestRequest]
testRequests = [testReq1, testReq2, testReq3, testReq4, testReq5]

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

testMetrics :: [TestMetric]
testMetrics = [testMetric1]

testMetric1 :: TestMetric
testMetric1 = TestMetric
  { metricNameTm = "/kadena/cluster/size"
  , evalTm = (\s -> readDef (0.0 :: Float) s == 4.0) }