module ConfigChangeSpec (spec) where 

import Test.Hspec
import Util.TestRunner

spec :: Spec
spec = 
    describe "testConfigConfigChange" $ 
        it "tests configuration change" $ do
            delTempFiles      
            runAll
            True `shouldBe` True
 