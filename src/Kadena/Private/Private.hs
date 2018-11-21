{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Kadena.Private.Private
  (kpPublic,kpSecret,
   initEntitySession,
   initLabeler,
   initRemote,
   initSessions,
   sendPrivate,
   handlePrivate)
  where


import Control.Arrow ((&&&))
import Control.Exception (Exception, SomeException)
import Control.Lens
       ((.=), (%=), use, ix, view, over, set)
import Control.Monad (forM, forM_, when)
import Control.Monad.Catch (MonadThrow, MonadCatch, throwM, handle)
import Control.Monad.State.Strict (MonadState, get, put)
import Crypto.Noise ( defaultHandshakeOpts, HandshakePattern, HandshakeOpts, HandshakeRole(..)
                    , noiseState, writeMessage, readMessage, setLocalStatic, setLocalEphemeral
                    , setRemoteStatic, NoiseResult(..), NoiseState )
import Crypto.Noise.Cipher (Cipher(..), Plaintext)
import Crypto.Noise.DH (KeyPair, DH(..))
import Crypto.Noise.DH.Curve25519 (Curve25519)
import Crypto.Noise.HandshakePatterns (noiseK)
import Data.ByteArray (ScrubbedBytes, convert)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B8
import qualified Data.HashMap.Strict as HM
import Data.Monoid ((<>))
import Data.Serialize (encode, decode)
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Set as S

import Pact.Types.Orphans ()
import Pact.Types.Util (AsString(..))

import Kadena.Types.Private
import Kadena.Types.Entity

noise :: HandshakePattern -> HandshakeRole
        -> EntityLocal -> PublicKey Curve25519
        -> Noise
noise pat rol EntityLocal{..} remoteStatic =
  let dho = defaultHandshakeOpts rol "prologue" :: HandshakeOpts Curve25519
      iho = setLocalStatic (Just (toKeyPair _elStatic))
            . setRemoteStatic (Just remoteStatic)
            . setLocalEphemeral (Just (toKeyPair _elEphemeral))
            $ dho
  in noiseState iho pat

kpPublic :: KeyPair a -> PublicKey a
kpPublic = snd

kpSecret :: KeyPair a -> SecretKey a
kpSecret = fst

data NoiseMessageException = NoiseMessageException String
    deriving Show

instance Exception NoiseMessageException

initEntitySession :: EntityLocal -> EntitySession
initEntitySession el@EntityLocal{..} = EntitySession
  (noise noiseK InitiatorRole el (_ekPublic _elStatic))
  (noise noiseK ResponderRole el (_ekPublic _elStatic))
  lblr lblr (makeLabel lblr) 0
  where lblr = initLabeler (encodeUtf8 $ asString _elName)
               (_ekSecret _elStatic) (_ekPublic _elStatic)

initLabeler :: ByteString -> SecretKey Curve25519 -> PublicKey Curve25519 -> Labeler
initLabeler ad sk pk = Labeler (cipherBytesToSym $ dhPerform sk pk) cipherZeroNonce (convert ad)

initRemote :: MonadThrow m => EntityLocal -> EntityRemote -> m RemoteSession
initRemote el@EntityLocal{..} EntityRemote{..} = do
  let outName = asString _elName <> ":" <> asString _erName
      inName = asString _erName <> ":" <> asString _elName
      sendL = initLabeler (encodeUtf8 outName) (_ekSecret _elStatic) $ _epPublic _erStatic
      recvL = initLabeler (encodeUtf8 inName) (_ekSecret _elStatic) $ _epPublic _erStatic
  return $ RemoteSession outName _erName
    (noise noiseK InitiatorRole el $ _epPublic _erStatic)
    (noise noiseK ResponderRole el $ _epPublic _erStatic)
    sendL recvL (makeLabel recvL) 0

initSessions :: MonadThrow m => EntityLocal -> [EntityRemote] -> m Sessions
initSessions el ers = do
  ss <- fmap HM.fromList $ forM ers $ \er -> (_erName er,) <$> initRemote el er
  let ls = HM.fromList $ map (_rsLabel &&& _rsEntity) $ HM.elems ss
  return $ Sessions (initEntitySession el) ss ls

labelPT :: Plaintext
labelPT = convert $ B8.pack $ replicate 12 (toEnum 0)

makeLabel :: Labeler -> Label
makeLabel Labeler{..} = convert $ cipherTextToBytes $
                        cipherEncrypt _lSymKey _lNonce _lAssocData labelPT

updateLabeler :: Labeler -> Labeler
updateLabeler = over lNonce cipherIncNonce

withStateRollback :: (MonadState s m,MonadCatch m) => (s -> m a) -> m a
withStateRollback act = get >>= \s -> handle (\(e :: SomeException) -> put s >> throwM e) (act s)

lookupRemote :: EntityName -> HM.HashMap EntityName RemoteSession -> Private RemoteSession
lookupRemote to = maybe (die $ "lookupRemote: invalid entity: " ++ show to) return .
                  HM.lookup to

-- | Send updates entity outbound labeler, entity init noise, remote send labeler, remote noise.
sendPrivate :: PrivatePlaintext -> Private PrivateCiphertext
sendPrivate pm@PrivatePlaintext{..} = withStateRollback $ \(PrivateState Sessions {..}) -> do
  let pt = convert $ encode pm
  entName <- view $ entityLocal . elName
  remotePayloads <- forM (S.toList _ppTo) $ \to -> do
    when (to == entName) $ die "sendPrivate: sending to same entity!"
    RemoteSession {..} <- lookupRemote to _sRemotes
    case writeMessage pt _rsSendNoise of
      NoiseResultException e -> throwM e
      NoiseResultNeedPSK _ -> throwM $ NoiseMessageException "NoiseREsultNeedPSK is not implemented"
      (NoiseResultMessage ct n') -> do
        sessions . sRemotes . ix to %=
          (set rsSendNoise n' . over rsSendLabeler updateLabeler . over rsVersion succ)
        return $ Labeled (makeLabel _rsSendLabeler) (convert ct)
  entityPayload <- do
    case writeMessage pt (_esSendNoise _sEntity) of
      NoiseResultException e -> throwM e
      NoiseResultNeedPSK _ -> throwM $ NoiseMessageException "NoiseREsultNeedPSK is not implemented"
      (NoiseResultMessage ct n') -> do
        sessions . sEntity %= (set esSendNoise n' . over esSendLabeler updateLabeler . over esVersion succ)
        return $ Labeled (makeLabel (_esSendLabeler _sEntity)) (convert ct)
  return $ PrivateCiphertext entityPayload remotePayloads

-- | Switch on message labels to handle as same-entity or remote-inbound message.
handlePrivate :: PrivateCiphertext -> Private (Maybe PrivatePlaintext)
handlePrivate pe@PrivateCiphertext{..} = do
  Sessions{..} <- use sessions
  if _lLabel _pcEntity == _esLabel _sEntity
    then Just <$> readEntity pe
    else let testRemote _ done@Just {} = done
             testRemote ll@Labeled{..} Nothing =
               (ll,) <$> HM.lookup _lLabel _sLabels
         in mapM readRemote $ foldr testRemote Nothing _pcRemotes

-- | inbound entity updates entity inbound labeler, label, inbound entity resp noise. If not sender,
-- also retro-update entity out labeler, entity init noise, remote send labeler, remote noise.
readEntity :: PrivateCiphertext -> Private PrivatePlaintext
readEntity PrivateCiphertext{..} = do
  Sessions{..} <- use sessions
  let f pt n' = do
        pm@PrivatePlaintext{..} <- liftEither "readEntity:deser" $ decode (convert pt)
        me <- view nodeAlias
        let ilblr = updateLabeler $ _esRecvLabeler _sEntity
            update = set esRecvNoise n' . set esLabel (makeLabel ilblr) . set esRecvLabeler ilblr . over esVersion succ
        if _ppSender == me then sessions . sEntity %= update
        else do
          let g _ in' = do
                sessions . sEntity %= update . set esSendNoise in' . over esSendLabeler updateLabeler
                forM_ (S.toList _ppTo) $ \to -> do
                  RemoteSession{..} <- lookupRemote to _sRemotes
                  let h _ rn' = do
                        sessions . sRemotes . ix to %=
                          set rsSendNoise rn' . over rsSendLabeler updateLabeler . over rsVersion succ
                  handleResult h $ writeMessage pt _rsSendNoise
          handleResult g $ writeMessage pt (_esSendNoise _sEntity)
        return pm
  handleResult f $ readMessage (convert (_lPayload _pcEntity)) (_esRecvNoise _sEntity)

-- | inbound remote updates remote label, recv labeler, remote noise.
readRemote :: (Labeled,EntityName) -> Private PrivatePlaintext
readRemote (Labeled{..},remoteEntName) = do
  rs@RemoteSession{..} <- lookupRemote remoteEntName =<< use (sessions . sRemotes)
  let f pt n' = do
        let l' = updateLabeler _rsRecvLabeler
            lbl = makeLabel l'
            rs' = set rsRecvNoise n' . set rsRecvLabeler l' . set rsLabel lbl . over rsVersion succ $ rs
        sessions . sLabels %= HM.insert lbl _rsEntity . HM.delete _lLabel
        sessions . sRemotes . ix _rsEntity .= rs'
        liftEither "readRemote:deser" $ decode (convert pt)
  handleResult f $ readMessage (convert _lPayload) _rsRecvNoise

-- Reducing the repetition of NoiseResult case handling a bit...
handleResult :: (ScrubbedBytes -> (NoiseState c d h) -> (Private a))
             -> (NoiseResult c d h) -> Private a
handleResult f (NoiseResultMessage sb ns) = f sb ns
handleResult _ (NoiseResultNeedPSK _) = throwM $ NoiseMessageException "NoiseREsultNeedPSK is not implemented"
handleResult _ (NoiseResultException e) = throwM e
