module ConfigChangeSpec (spec) where 

import Safe
import Test.Hspec
import Util.TestRunner

spec :: Spec
spec = 
    describe "testClusterCommands" $ 
        it "tests commands send to a locally running cluster" $ do
            delTempFiles      
            (results, metrics) <- runAll testRequests testMetrics
            ok <- checkResults results 
            ok `shouldBe` True
            metricsOk <- checkMetrics metrics
            metricsOk `shouldBe` True

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
  , eval = resultSuccess
  , displayStr = "Executes 1 + 1 in Pact" } 

testReq2 :: TestRequest
testReq2 = TestRequest 
  { cmd = "load test-files/test.yaml"
  , matchCmd = "test-files/test.yaml"
  , eval = resultSuccess
  , displayStr = "Loads the Pact configuration file test.yaml" }        
  
testReq3 :: TestRequest
testReq3 = TestRequest 
  { cmd = "exec (test.create-global-accounts)"
  , matchCmd = "exec (test.create-global-accounts)"
  , eval = resultSuccess
  , displayStr = "Executes the create-global-accounts Pact function" }  

testReq4 :: TestRequest
testReq4 = TestRequest 
  { cmd = "exec (test.transfer \"Acct1\" \"Acct2\" 1.00)"
  , matchCmd = "exec (test.transfer \"Acct1\" \"Acct2\" 1.00)"
  , eval = resultSuccess
  , displayStr = "Executes a Pact function transferring 1.00 from Acct1 to Acct2" }  

testReq5 :: TestRequest
testReq5 = TestRequest 
  { cmd = "batch 4000"
  , matchCmd = "(test.transfer \"Acct1\" \"Acct2\" 1.00)"
  , eval = resultSuccess
  , displayStr = "Executes the function transferring 1.00 from Acct 1 to Acc2 4000 times" }  

testMetrics :: [TestMetric]
testMetrics = [testMetric1]

testMetric1 :: TestMetric
testMetric1 = TestMetric
  { metricNameTm = "kadena_cluster_size"
  , evalTm = (\s -> readDef (0.0 :: Float) s == 4.0) } 