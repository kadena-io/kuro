{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Kadena.Private

  where


import Crypto.Noise.DH (KeyPair, DH(..)  )
import Crypto.Noise.DH.Curve25519 (Curve25519)
import Crypto.Noise (HandshakeOpts,defaultHandshakeOpts,HandshakeRole(..)
                    ,hoLocalStatic,hoRemoteStatic,hoLocalEphemeral
                    ,NoiseState,noiseState,writeMessage,readMessage)
import Crypto.Noise.HandshakePatterns (HandshakePattern,noiseKK,noiseK)
import Crypto.Noise.Cipher.AESGCM (AESGCM)
import Crypto.Noise.Hash.SHA256 (SHA256)
import Data.ByteArray.Extend (convert)
import Data.Monoid ((<>))
import Control.Lens ((&),(.~))
import Control.Concurrent.Chan (Chan,newChan,readChan,writeChan)
import Control.Concurrent (forkIO)
import Data.ByteString (ByteString)
import Control.Monad (unless,void,forM)
import Control.Exception (throwIO)
import Data.String (IsString)
import qualified Data.HashMap.Strict as HM
import Data.Hashable (Hashable)
import Control.Monad.Catch (MonadThrow,throwM)
import qualified Data.Set as S
import Data.Serialize (Serialize (..))
import GHC.Generics (Generic)
import Data.Text (Text)
import Control.DeepSeq

import Pact.Types.Orphans ()

newtype EntityName = EntityName Text
  deriving (IsString,Eq,Show,Ord,Hashable,Serialize,NFData)

type Noise = NoiseState AESGCM Curve25519 SHA256

data EntityLocal = EntityLocal {
    _elName :: EntityName
  , _elStatic :: KeyPair Curve25519
  , _elEphemeral :: KeyPair Curve25519
  }

data EntityRemote = EntityRemote {
    _erName :: EntityName
  , _erStatic :: PublicKey Curve25519
  }

data InteractiveSession = InteractiveSession {
    _isState :: Noise
  , _isRole :: HandshakeRole
  }

data EntitySession = EntitySession {
    _esInitState :: Noise
  , _esRespState :: Noise
  }


data Sessions = Sessions {
    _entitySession :: EntitySession
  , _sessions :: HM.HashMap EntityName InteractiveSession
  }

data PrivateMessage = PrivateMessage {
    _pmFrom :: EntityName
  , _pmTo :: S.Set EntityName
  , _pmMessage :: ByteString
  } deriving (Eq,Show,Generic)
instance Serialize PrivateMessage

noise :: HandshakePattern -> HandshakeRole
        -> EntityLocal -> PublicKey Curve25519
        -> Noise
noise pat rol EntityLocal{..} remoteStatic =
  noiseState $ defaultHandshakeOpts pat rol &
      hoLocalStatic .~ Just _elStatic &
      hoRemoteStatic .~ Just remoteStatic &
      hoLocalEphemeral .~ Just _elEphemeral

kpPublic :: KeyPair a -> PublicKey a
kpPublic = snd

initEntitySession :: EntityLocal -> EntitySession
initEntitySession el = EntitySession
  (noise noiseK InitiatorRole el (kpPublic (_elStatic el)))
  (noise noiseK ResponderRole el (kpPublic (_elStatic el)))

initInteractive :: MonadThrow m => EntityLocal -> EntityRemote -> m InteractiveSession
initInteractive el@EntityLocal{..} EntityRemote{..} = do
  rol <- case _elName `compare` _erName of
    LT -> return InitiatorRole
    GT -> return ResponderRole
    EQ -> throwM (userError $ "initInteractive: local and remote names match: " ++ show (_elName,_erName))
  return $ InteractiveSession (noise noiseKK rol el _erStatic) rol

initSessions :: MonadThrow m => EntityLocal -> [EntityRemote] -> m Sessions
initSessions el ers = do
  ss <- fmap HM.fromList $ forM ers $ \er -> (_erName er,) <$> initInteractive el er
  return $ Sessions (initEntitySession el) ss




-- ========================= TOY CODE BELOW ==========================


liftEither :: Show e => String -> Either e a -> IO a
liftEither a = either (\e -> throwIO (userError $ a ++ ": ERROR: " ++ show e)) return

runInitiator :: KeyPair Curve25519 -> KeyPair Curve25519 ->
                PublicKey Curve25519 -> (Chan ByteString,Chan ByteString) -> [ByteString] -> IO ()
runInitiator localKeyPair locEphKey responderPublicKey (outChan,inChan) msgs =
  loop state (msgs ++ ["DONE"])
  where
    handshakeOpts :: HandshakeOpts Curve25519
    handshakeOpts = defaultHandshakeOpts noiseKK InitiatorRole &
      hoLocalStatic .~ Just localKeyPair &
      hoRemoteStatic .~ Just responderPublicKey &
      hoLocalEphemeral .~ Just locEphKey
    state :: NoiseState AESGCM Curve25519 SHA256
    state = noiseState handshakeOpts
    loop _ [] = return ()
    loop s (msg:ms) = do
      putStrLn $ "INITIATOR: send: " ++ show msg
      (ct,s') <- liftEither "INITIATOR" $ writeMessage s (convert msg)
      writeChan outChan ct
      --(pct,_) <- liftEither "INITIATOR-read self" $ readMessage s' ct
      --putStrLn $ "INITIATOR: read self: " ++ show (convert pct :: ByteString)
      inMsg <- readChan inChan
      (pt,s'') <- liftEither "INITIATOR" $ readMessage s' inMsg
      putStrLn $ "INITIATOR: receive: " ++ show (convert pt :: ByteString)
      loop s'' ms

runRespondent :: KeyPair Curve25519 -> KeyPair Curve25519 ->
                 PublicKey Curve25519 -> (Chan ByteString,Chan ByteString) -> IO ()
runRespondent localKeyPair locEphKey initiatorPublicKey (outChan,inChan) =
  loop state state True
  where
    handshakeOpts :: HandshakeOpts Curve25519
    handshakeOpts = defaultHandshakeOpts noiseKK ResponderRole &
      hoLocalStatic .~ Just localKeyPair &
      hoRemoteStatic .~ Just initiatorPublicKey &
      hoLocalEphemeral .~ Just locEphKey
    state :: NoiseState AESGCM Curve25519 SHA256
    state = noiseState handshakeOpts
    loop sL sR flip = do
      let (s1,s2) = if flip then (sL,sR) else (sR,sL)
      inMsg <- readChan inChan
      (pt,s1') <- liftEither "RESPONDENT" (readMessage s1 inMsg)
      (_,s2') <- liftEither "RESPONDENT" (readMessage s2 inMsg)
      let (msg :: ByteString) = convert pt
          done = msg == "DONE"
      putStrLn $ "RESPONDENT: receive: " ++ show msg ++ (if done then " ==> DONE" else "")
      (ct,s1'') <- liftEither "RESPONDENT" $ writeMessage s1' (convert $ "ACK: " <> msg)
      (_,s2'') <- liftEither "RESPONDENT" $ writeMessage s2' (convert $ "ACK: " <> msg)
      writeChan outChan ct
      unless done $ loop s1'' s2'' (not flip)

runOneWay :: IO ()
runOneWay = do
  initKeyPair@(_,initPubKey) <- dhGenKey
  initLocEphKey <- dhGenKey
  respKeyPair@(_,respPubKey) <- dhGenKey
  respLocEphKey <- dhGenKey
  let
    initState :: NoiseState AESGCM Curve25519 SHA256
    initState = noiseState $ defaultHandshakeOpts noiseK InitiatorRole &
                hoLocalStatic .~ Just initKeyPair &
                hoRemoteStatic .~ Just respPubKey &
                hoLocalEphemeral .~ Just initLocEphKey
    respState :: NoiseState AESGCM Curve25519 SHA256
    respState = noiseState $ defaultHandshakeOpts noiseK ResponderRole &
                hoLocalStatic .~ Just respKeyPair &
                hoRemoteStatic .~ Just initPubKey &
                hoLocalEphemeral .~ Just respLocEphKey
    msgs :: [ByteString]
    msgs = ["A","B","C","D"]
    loop [] _ _ = return ()
    loop (m:ms) is rs = do

      putStrLn $ "INITIATOR: send: " ++ show m
      (ct,is') <- liftEither "INITIATOR" $ writeMessage is (convert m)

      (pt,rs') <- liftEither "RESPONDENT" $ readMessage rs ct
      let (m' :: ByteString) = convert pt
      putStrLn $ "RESPONDENT: receive: " ++ show m'

      loop ms is' rs'

  loop msgs initState respState

main :: IO ()
main = do
  initKeyPair@(_,initPubKey) <- dhGenKey
  respKeyPair@(_,respPubKey) <- dhGenKey
  initLocEphKey <- dhGenKey
  respLocEphKey <- dhGenKey
  i2rChan <- newChan
  r2iChan <- newChan
  putStrLn "Starting respondent"
  void $ forkIO $ runRespondent respKeyPair respLocEphKey initPubKey (r2iChan,i2rChan)
  putStrLn "Starting initiator"
  runInitiator initKeyPair initLocEphKey respPubKey (i2rChan,r2iChan)
    ["A","B","C","D"]
  putStrLn "Done"
