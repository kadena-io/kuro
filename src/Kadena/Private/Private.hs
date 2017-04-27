{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Kadena.Private

  where


import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.DeepSeq (NFData)
import Control.Exception (Exception,SomeException)
import Control.Lens ((&), (.~), (.=), (%=), use, makeLenses, ix, view, over, set)
import Control.Monad (unless, void, forM, zipWithM_)
import Control.Monad.Catch (MonadThrow, MonadCatch, throwM, handle)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.State.Strict
       (MonadState(..), StateT(..), runStateT, get, modify)
import Control.Monad.Reader (MonadReader(..),ReaderT(..),runReaderT,ask)
import Crypto.Noise
       (HandshakeOpts, defaultHandshakeOpts, HandshakeRole(..),
        hoLocalStatic, hoRemoteStatic, hoLocalEphemeral, NoiseState,
        noiseState, writeMessage, readMessage)
import Crypto.Noise.Cipher (Cipher (..), Plaintext, AssocData)
import Crypto.Noise.Cipher.AESGCM (AESGCM)
import Crypto.Noise.DH (KeyPair, DH(..))
import Crypto.Noise.DH.Curve25519 (Curve25519)
import Crypto.Noise.HandshakePatterns
       (HandshakePattern, noiseKK, noiseK)
import Crypto.Noise.Hash.SHA256 (SHA256)
import Data.ByteArray.Extend (convert,ScrubbedBytes)
import Data.ByteArray (ByteArray,ByteArrayAccess)
import Data.ByteString.Char8 (ByteString,pack)
import qualified Data.HashMap.Strict as HM
import Data.Hashable (Hashable)
import Data.Monoid ((<>),Monoid(..))
import Data.Serialize (Serialize, encode, decode)
import qualified Data.Set as S
import Data.String (IsString)
import Data.Text (Text,unpack)
import Data.Word (Word64)
import GHC.Generics (Generic)

import Kadena.Types.Base (NodeId(..))

import Pact.Types.Orphans ()
import Pact.Types.Util (AsString(..))


newtype EntityName = EntityName Text
  deriving (IsString,AsString,Eq,Show,Ord,Hashable,Serialize,NFData)

newtype Label = Label ByteString
  deriving (IsString,Eq,Show,Ord,Hashable,Serialize,NFData,Monoid,ByteArray,ByteArrayAccess)

type Noise = NoiseState AESGCM Curve25519 SHA256

data Labeler = Labeler {
    _lSymKey :: SymmetricKey AESGCM
  , _lNonce :: Nonce AESGCM
  , _lAssocData :: AssocData
  }
makeLenses ''Labeler

data EntityLocal = EntityLocal {
    _elName :: EntityName
  , _elStatic :: KeyPair Curve25519
  , _elEphemeral :: KeyPair Curve25519
  }

data EntityRemote = EntityRemote {
    _erName :: EntityName
  , _erStatic :: PublicKey Curve25519
  }

data RemoteSession = RemoteSession {
    _rsName :: Text
  , _rsNoise :: Noise
  , _rsRole :: HandshakeRole
  , _rsSendLabeler :: Labeler
  , _rsRecvLabeler :: Labeler
  , _rsLabel :: Label
  }
makeLenses ''RemoteSession
instance Show RemoteSession where show RemoteSession{..} = show _rsName

data EntitySession = EntitySession {
    _esInitNoise :: Noise
  , _esRespNoise :: Noise
  , _esLabeler :: Labeler
  , _esLabel :: Label
  }
makeLenses ''EntitySession


data Sessions = Sessions {
    _sEntity :: EntitySession
  , _sRemotes :: HM.HashMap EntityName RemoteSession
  , _sLabels :: HM.HashMap Label RemoteSession
  }
makeLenses ''Sessions


data PrivateMessage = PrivateMessage {
    _pmFrom :: EntityName
  , _pmSender :: NodeId
  , _pmTo :: S.Set EntityName
  , _pmMessage :: ByteString
  } deriving (Eq,Show,Generic)
instance Serialize PrivateMessage

newtype PrivateException = PrivateException String
  deriving (Eq,Show,Ord,IsString)
instance Exception PrivateException

data Labeled = Labeled {
    _lLabel :: Label
  , _lPayload :: ByteString
  } deriving (Generic)
instance Serialize Labeled

data PrivateEnvelope = PrivateEnvelope {
    _peEntity :: Labeled
  , _peRemotes :: [Labeled]
  } deriving (Generic)
instance Serialize PrivateEnvelope

data PrivateEnv = PrivateEnv {
    _entityLocal :: EntityLocal
  , _entityRemotes :: [EntityRemote]
  , _nodeId :: NodeId
  }
makeLenses ''PrivateEnv

data PrivateState = PrivateState {
      _sessions :: Sessions
  }
makeLenses ''PrivateState

liftEither :: (Show e,MonadThrow m) => String -> Either e a -> m a
liftEither a = either (\e -> die $ a ++ ": ERROR: " ++ show e) return

die :: MonadThrow m => String -> m a
die = throwM . PrivateException

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

kpSecret :: KeyPair a -> SecretKey a
kpSecret = fst

initEntitySession :: EntityLocal -> EntitySession
initEntitySession el@EntityLocal{..} = EntitySession
  (noise noiseK InitiatorRole el (kpPublic _elStatic))
  (noise noiseK ResponderRole el (kpPublic _elStatic))
  lblr lbl
  where (lbl,lblr) = initLabeler (convert $ pack $ unpack $ asString _elName)
                     (kpSecret _elStatic) (kpPublic _elStatic)

initLabeler :: AssocData -> SecretKey Curve25519 -> PublicKey Curve25519 -> (Label,Labeler)
initLabeler ad sk pk = (makeLabel lblr,lblr) where
  lblr = Labeler (cipherBytesToSym $ dhPerform sk pk) cipherZeroNonce ad

initRemote :: MonadThrow m => EntityLocal -> EntityRemote -> m RemoteSession
initRemote el@EntityLocal{..} EntityRemote{..} = do
  (rol,name) <- case _elName `compare` _erName of
    LT -> return (InitiatorRole, asString _elName <> ":" <> asString _erName)
    GT -> return (ResponderRole, asString _erName <> ":" <> asString _elName)
    EQ -> throwM (userError $ "initRemote: local and remote names match: " ++ show (_elName,_erName))
  let (lbl,lblr) = initLabeler (convert $ pack $ unpack name) (kpSecret _elStatic) _erStatic
  return $ RemoteSession name
    (noise noiseKK rol el _erStatic) rol lblr lblr lbl



initSessions :: MonadThrow m => EntityLocal -> [EntityRemote] -> m Sessions
initSessions el ers = do
  ss <- fmap HM.fromList $ forM ers $ \er -> (_erName er,) <$> initRemote el er
  let ls = HM.fromList $ map (\is -> (_rsLabel is,is)) $ HM.elems ss
  return $ Sessions (initEntitySession el) ss ls


labelPT :: Plaintext
labelPT = convert $ pack $ replicate 12 (toEnum 0)

makeLabel :: Labeler -> Label
makeLabel Labeler{..} = convert $ cipherTextToBytes $
                        cipherEncrypt _lSymKey _lNonce _lAssocData labelPT

updateLabeler :: Labeler -> Labeler
updateLabeler = over lNonce cipherIncNonce

withStateRollback :: (MonadState s m,MonadCatch m) => (s -> m a) -> m a
withStateRollback act = get >>= \s -> handle (\(e :: SomeException) -> put s >> throwM e) (act s)

-- | Send updates entity labeler, entity init noise, remote send labeler, remote noise.
sendPrivate :: (MonadState PrivateState m, MonadCatch m) => PrivateMessage -> m PrivateEnvelope
sendPrivate pm@PrivateMessage{..} = withStateRollback $ \(PrivateState Sessions {..}) -> do
  let pt = convert $ encode pm
  remotePayloads <- forM (S.toList _pmTo) $ \to -> case HM.lookup to _sRemotes of
    Nothing -> die $ "sendPrivate: invalid entity: " ++ show to
    Just RemoteSession{..} -> do
      (ct,n') <- liftEither ("sendPrivate:" ++ show to) $ writeMessage _rsNoise pt
      sessions . sRemotes . ix to %= (set rsNoise n' . over rsSendLabeler updateLabeler)
      return $ Labeled (makeLabel _rsSendLabeler) (convert ct)
  entityPayload <- do
    (ct,n') <- liftEither "sendPrivate:entity" $ writeMessage (_esInitNoise _sEntity) pt
    sessions . sEntity %= (set esInitNoise n' . over esLabeler updateLabeler)
    return $ Labeled (makeLabel (_esLabeler _sEntity)) (convert ct)
  return $ PrivateEnvelope entityPayload remotePayloads

-- | Switch on message labels to handle as same-entity or remote-inbound message.
handlePrivate :: (MonadState PrivateState m, MonadReader PrivateEnv m, MonadThrow m) =>
                 PrivateEnvelope -> m (Maybe PrivateMessage)
handlePrivate pe@PrivateEnvelope{..} = do
  Sessions{..} <- use sessions
  if _lLabel _peEntity == _esLabel _sEntity
    then Just <$> handleEntityPrivate pe
    else let testRemote _ done@Just {} = done
             testRemote ll@Labeled{..} Nothing =
               (ll,) <$> HM.lookup _lLabel _sLabels
         in mapM handleRemotePrivate $ foldr testRemote Nothing _peRemotes

-- | inbound entity updates entity label, entity resp noise. If not sender,
-- also retro-update entity labeler, entity init noise, remote send labeler, remote noise.
handleEntityPrivate :: (MonadState PrivateState m, MonadReader PrivateEnv m, MonadThrow m) =>
                 PrivateEnvelope -> m PrivateMessage
handleEntityPrivate = undefined

-- | inbound remote updates remote label, recv labeler, remote noise.
handleRemotePrivate :: (MonadState PrivateState m, MonadThrow m) =>
                 (Labeled,RemoteSession) -> m PrivateMessage
handleRemotePrivate (Labeled{..},rs@RemoteSession{..}) = do
  let lblr' = undefined -- over _rsRecvLabeler
  sessions . sLabels %= HM.delete _lLabel
  undefined
-- ========================= TOY CODE BELOW ==========================


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


checkDH :: IO ()
checkDH = do
  (sk1,pk1) :: KeyPair Curve25519 <- dhGenKey
  (sk2,pk2) :: KeyPair Curve25519 <- dhGenKey
  let dh12 = dhPerform sk1 pk2
      dh21 = dhPerform sk2 pk1
      (sym12 :: SymmetricKey AESGCM) = cipherBytesToSym dh12
      (sym21 :: SymmetricKey AESGCM) = cipherBytesToSym dh21
      ad = convert ("" :: ByteString)
      ct = cipherEncrypt sym12 cipherZeroNonce ad (convert ("Message" :: ByteString))
      pt = cipherDecrypt sym21 cipherZeroNonce ad ct
  print (fmap convert pt :: Maybe ByteString)

mkRemotes :: IO (RemoteSession,RemoteSession)
mkRemotes = do
  (kpAS,kpAE,kpBS,kpBE) <- (,,,) <$> dhGenKey <*> dhGenKey <*> dhGenKey <*> dhGenKey
  (,) <$> initRemote (EntityLocal "A" kpAS kpAE) (EntityRemote "B" $ kpPublic kpBS)
      <*> initRemote (EntityLocal "B" kpBS kpBE) (EntityRemote "A" $ kpPublic kpAS)
