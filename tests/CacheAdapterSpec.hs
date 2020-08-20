module CacheAdapterSpec where

import Test.Hspec

import qualified Pact.Persist.CacheAdapter as CacheAdapter

spec :: Spec
spec = describe "tests for CacheAdapter" cacheAdapterTests

cacheAdapterTests :: Spec
cacheAdapterTests = do
    it "Runs a regression test on an in-memory version of SQLite" $ do
        CacheAdapter.regressPureSQLite
        True `shouldBe` True
    it "Runs a write-behind test" $ do
        CacheAdapter.runDemoWB
        True `shouldBe` True
