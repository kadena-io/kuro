{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

module ConfigSpec where

import Data.Aeson
import qualified Data.Set as S
import qualified Data.HashSet as HS
import qualified Data.Map.Strict as M
import qualified Data.HashMap.Strict as HM
import "crypto-api" Crypto.Random
import Crypto.Ed25519.Pure

import Kadena.Types.Config
import Kadena.Types.Base
import Kadena.Types.Entity

import qualified Pact.Types.Crypto as Signing
import Pact.Types.Logger

import Test.Hspec

spec :: Spec
spec = do
  describe "testConfigRT" $ testConfigRT


makeKeys :: CryptoRandomGen g => Int -> g -> [(PrivateKey,PublicKey)]
makeKeys 0 _ = []
makeKeys n g = case generateKeyPair g of
  Left err -> error $ show err
  Right (s,p,g') -> (s,p) : makeKeys (n-1) g'

dummyConfig :: IO Config
dummyConfig = do
  [(as,ap),(_bs,bp),(_cs,cp)] <- makeKeys 3 <$> (newGenIO :: IO SystemRandom)
  aStatic <- genKeyPair
  aEph <- genKeyPair
  bStatic <- genKeyPair

  let toPub = EntityPublicKey . _ekPublic
      aRemote = EntityRemote "A" (toPub $ aStatic)
      bRemote = EntityRemote "B" (toPub $ bStatic)

  return $ Config
    { _otherNodes           = S.fromList [NodeId "hostB" 8001 "hostB:8001" "B",
                                          NodeId "hostC" 8002 "hostB:8002" "C"]
    , _nodeId               = NodeId "hostA" 8000 "hostA:8000" "A"
    , _publicKeys           = M.fromList [("hostB",bp),("hostC",cp)]
    , _adminKeys            = M.fromList [("hostA",ap),("hostC",cp)]
    , _myPrivateKey         = as
    , _myPublicKey          = ap
    , _electionTimeoutRange = (6,7)
    , _heartbeatTimeout     = 5
    , _enableDebug          = True
    , _apiPort              = 4
    , _entity               = EntityConfig
        { _ecLocal = EntityLocal "A" aStatic aEph
        , _ecRemotes = [aRemote,bRemote]
        , _ecSending = True
        , _ecSigner = Signer (Signing.ED25519,as,ap)
        }
    , _logDir               = "/tmp/foo"
    , _enablePersistence    = False
    , _pactPersist          = PactPersistConfig
        { _ppcWriteBehind = False
        , _ppcBackend = PPBInMemory }
    , _aeBatchSize          = 2
    , _preProcThreadCount   = 3
    , _preProcUsePar        = True
    , _inMemTxCache         = 1
    , _hostStaticDir        = False
    , _nodeClass            = Active
    , _logRules             = LogRules $ HM.fromList
                              [("Foo", LogRule
                                       { enable = Just True,
                                         include = Nothing,
                                         exclude = Just (HS.singleton "DEBUG")
                                       })]

    }

testConfigRT :: Spec
testConfigRT = do
  c <- runIO $ dummyConfig
  let cenc = encode c
  case eitherDecode cenc :: Either String Config of
    Left err -> it "decodes" $ expectationFailure $ "decode failed: " ++ err
    Right cdec -> do
      it "roundtrips" $ encode cdec `shouldBe` cenc