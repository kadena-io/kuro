module ConfigChangeSpec (spec) where 

import Test.Hspec
import Util.TestRunner

spec :: Spec
spec = 
    describe "testConfigConfigChange" $ 
        it "tests configuration change" $ do
            delTempFiles      
            results <- runAll testRequests
            ok <- checkResults results 
            ok `shouldBe` True

checkResults :: [TestResult] -> IO Bool
checkResults xs = 
    foldr checkResult (return True) xs where
        checkResult :: TestResult -> IO Bool -> IO Bool
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
                      else return $ r && bOk
                    
failTest :: TestResult -> String -> IO ()
failTest tr addlInfo = do
    putStrLn $ "Test failure: " ++ cmd (requestTr tr) 
    putStrLn $ "(" ++ addlInfo ++ ")"

testRequests :: [TestRequest]
testRequests = [testReq1, testReq2, testReq3, testReq4, testReq5, testReq6]

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
  { cmd = "local (test.read-all-global)"
  , matchCmd = "local (test.read-all-global)"
  , eval = resultSuccess
  , displayStr = "Reads the commited results" }  

testReq6 :: TestRequest
testReq6 = TestRequest 
  { cmd = "batch 4000"
  , matchCmd = "(test.transfer \"Acct1\" \"Acct2\" 1.00)"
  , eval = resultSuccess
  , displayStr = "Executes the function transferring 1.00 from Acct 1 to Acc2 4000 times" }  