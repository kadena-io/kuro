module ConfigChangeSpec (spec) where 

import System.Time.Extra    
import Test.Hspec
import Util.TestRunner

spec :: Spec
spec = 
    describe "testConfigConfigChange" $ 
        it "tests configuration change" $ do
            delTempFiles      
            
            serverHandles <- runServers
            -- runServers

            putStrLn $ "Servers are running, sleeping for 3 seconds"
            _ <- sleep 5
            
            let args = words $ "-c " ++ testConfDir ++ "client.yaml"
            runClientCommands args

            -- putStrLn $ "Client command sent"
            -- _ <- sleep 5

            stopProcesses serverHandles
          
            True `shouldBe` True
 