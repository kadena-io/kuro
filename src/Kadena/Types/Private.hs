{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Kadena.Types.Private
  ( EntityName(..)
  ,Label(..)
  ,Labeler(..)
  ,Labeled(..)
  ,Noise
  ,lSymKey,lNonce,lAssocData
  ,RemoteSession(..)
  ,rsName,rsEntity,rsSendNoise,rsRecvNoise,rsSendLabeler,rsRecvLabeler,rsLabel,rsVersion
  ,EntitySession(..)
  ,esSendNoise,esRecvNoise,esSendLabeler,esRecvLabeler,esLabel,esVersion
  ,Sessions(..)
  ,sEntity,sRemotes,sLabels
  ,PrivatePlaintext(..)
  ,PrivateCiphertext(..)
  ,PrivateEnv(..)
  ,entityLocal,entityRemotes,nodeAlias
  ,PrivateState(..)
  ,sessions
  ,liftEither,die
  ,Private(..)
  ,runPrivate
  ,PrivateRpc(..)
  ,PrivateChannel(..)
  ,PrivateResult(..)
    ) where


import Control.Concurrent (MVar)
import Control.Concurrent.Chan (Chan)
import Control.DeepSeq (NFData)
import Control.Exception (Exception,SomeException)
import Control.Lens (makeLenses)
import Control.Monad.Catch (MonadThrow, MonadCatch, throwM)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader
       (MonadReader(..), ReaderT(..), runReaderT)
import Control.Monad.State.Strict
       (MonadState(..), StateT(..), runStateT)
import Crypto.Noise (NoiseState)
import Crypto.Noise.Cipher (Cipher(..), AssocData)
import Crypto.Noise.Cipher.AESGCM (AESGCM)
import Crypto.Noise.DH.Curve25519 (Curve25519)
import Crypto.Noise.Hash.SHA256 (SHA256)
import Data.ByteArray (ByteArray, ByteArrayAccess)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8 as B8
import qualified Data.HashMap.Strict as HM
import Data.Hashable (Hashable)
import Data.Monoid ((<>))
import Data.Serialize (Serialize)
import qualified Data.Set as S
import Data.String (IsString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)
import GHC.Generics (Generic)
import Data.Aeson (ToJSON,FromJSON)

import Kadena.Types.Base (Alias(..))
import Kadena.Types.Comms (Comms(..),initCommsNormal,readCommNormal,writeCommNormal)
import Kadena.Types.Entity (EntityLocal,EntityRemote)

import Pact.Types.Orphans ()
import Pact.Types.Util (AsString(..))
import Pact.Types.Runtime (EntityName(..))


newtype Label = Label ByteString
  deriving (IsString,Eq,Ord,Hashable,Serialize,NFData,Monoid,ByteArray,ByteArrayAccess)
instance Show Label where show (Label l) = show (B16.encode l)
instance AsString Label where asString (Label l) = T.pack $ B8.unpack $ B16.encode l

type Noise = NoiseState AESGCM Curve25519 SHA256

data Labeler = Labeler {
    _lSymKey :: !(SymmetricKey AESGCM)
  , _lNonce :: !(Nonce AESGCM)
  , _lAssocData :: !AssocData
  }
makeLenses ''Labeler

data RemoteSession = RemoteSession {
    _rsName :: !Text
  , _rsEntity :: !EntityName
  , _rsSendNoise :: !Noise
  , _rsRecvNoise :: !Noise
  , _rsSendLabeler :: !Labeler
  , _rsRecvLabeler :: !Labeler
  , _rsLabel :: !Label
  , _rsVersion :: !Word64
  }
makeLenses ''RemoteSession
instance Show RemoteSession where
  show RemoteSession{..} =
    T.unpack (asString _rsName <> ",remote=" <>
              asString _rsEntity <> ",label=" <> asString _rsLabel <> ",v=") ++
    show _rsVersion

data EntitySession = EntitySession {
    _esSendNoise :: !Noise
  , _esRecvNoise :: !Noise
  , _esSendLabeler :: !Labeler
  , _esRecvLabeler :: !Labeler
  , _esLabel :: !Label
  , _esVersion :: !Word64
  }
makeLenses ''EntitySession
instance Show EntitySession where
  show EntitySession{..} = show ("Entity=" <> asString _esLabel)


data Sessions = Sessions {
    _sEntity :: !EntitySession
  , _sRemotes :: !(HM.HashMap EntityName RemoteSession)
  , _sLabels :: !(HM.HashMap Label EntityName)
  } deriving (Show)
makeLenses ''Sessions


data PrivatePlaintext = PrivatePlaintext {
    _ppFrom :: !EntityName
  , _ppSender :: !Alias
  , _ppTo :: !(S.Set EntityName)
  , _ppMessage :: !ByteString
  } deriving (Eq,Show,Generic)
instance Serialize PrivatePlaintext

newtype PrivateException = PrivateException String
  deriving (Eq,Show,Ord,IsString)
instance Exception PrivateException

data Labeled = Labeled {
    _lLabel :: !Label
  , _lPayload :: !ByteString
  } deriving (Generic,Eq)
instance Serialize Labeled
instance Show Labeled where
  show Labeled{..} = "label=" ++ show _lLabel ++ ",payload=" ++ show (B16.encode _lPayload)

data PrivateCiphertext = PrivateCiphertext {
    _pcEntity :: !Labeled
  , _pcRemotes :: ![Labeled]
  } deriving (Generic,Show,Eq)
instance Serialize PrivateCiphertext

data PrivateEnv = PrivateEnv {
    _entityLocal :: !EntityLocal
  , _entityRemotes :: ![EntityRemote]
  , _nodeAlias :: !Alias
  } deriving (Show)
makeLenses ''PrivateEnv

data PrivateState = PrivateState {
      _sessions :: !Sessions
  } deriving (Show)
makeLenses ''PrivateState

liftEither :: (Show e,MonadThrow m) => String -> Either e a -> m a
liftEither a = either (\e -> die $ a ++ ": ERROR: " ++ show e) return

die :: MonadThrow m => String -> m a
die = throwM . PrivateException

newtype Private a = Private { unPrivate :: StateT PrivateState (ReaderT PrivateEnv IO) a }
  deriving (Functor,Applicative,Monad,MonadIO,MonadThrow,MonadCatch,
            MonadState PrivateState,MonadReader PrivateEnv)

runPrivate :: PrivateEnv -> PrivateState ->
              Private a -> IO (a,PrivateState)
runPrivate e s a = runReaderT (runStateT (unPrivate a) s) e

data PrivateRpc =
  Encrypt {
    plaintext :: !PrivatePlaintext,
    cipherResult :: !(MVar (Either SomeException PrivateCiphertext))
    } |
  Decrypt {
    ciphertext :: !PrivateCiphertext,
    plainResult :: !(MVar (Either SomeException (Maybe PrivatePlaintext)))
    }


newtype PrivateChannel = PrivateChannel (Chan PrivateRpc)

instance Comms PrivateRpc PrivateChannel where
  initComms = PrivateChannel <$> initCommsNormal
  readComm (PrivateChannel c) = readCommNormal c
  writeComm (PrivateChannel c) = writeCommNormal c

data PrivateResult a =
  PrivateFailure !String
  | PrivatePrivate
  | PrivateSuccess a
  deriving (Show, Eq, Generic, Functor)
instance ToJSON a => ToJSON (PrivateResult a)
instance FromJSON a => FromJSON (PrivateResult a)
