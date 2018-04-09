module ConfigChangeSpec (spec) where 

import Control.Monad
import Test.Hspec
import Util.TestRunner

spec :: Spec
spec = 
    describe "testConfigConfigChange" $ 
        it "tests configuration change" $ do
            delTempFiles      
            results <- runAll
            -- _debugResults results
            all resultSuccess results `shouldBe` True

_debugResults :: [TestResult] -> IO ()
_debugResults results = do
    let pairs = zip ([1,2..] :: [Integer]) results
    forM_ pairs (\p -> do
        putStrLn $ "Results # " ++ show (fst p) ++ ": " 
        print $ resultSuccess $ snd p
        print $ apiResultsStr $ snd p)
