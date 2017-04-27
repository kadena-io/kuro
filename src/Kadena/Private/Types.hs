{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Kadena.Private.Types
  ( EntityName(..)
  ,Label(..)
  ,Labeler(..)
  ,Labeled(..)
  ,Noise
  ,lSymKey,lNonce,lAssocData
  ,EntityLocal(..)
  ,elName,elStatic,elEphemeral
  ,EntityRemote(..)
  ,erName,erStatic
  ,RemoteSession(..)
  ,rsName,rsEntity,rsNoise,rsRole,rsSendLabeler,rsRecvLabeler,rsLabel,rsVersion
  ,EntitySession(..)
  ,esInitNoise,esRespNoise,esLabeler,esLabel,esVersion
  ,Sessions(..)
  ,sEntity,sRemotes,sLabels
  ,PrivateMessage(..)
  ,PrivateEnvelope(..)
  ,PrivateEnv(..)
  ,entityLocal,entityRemotes,nodeAlias
  ,PrivateState(..)
  ,sessions
  ,liftEither,die
  ,Private(..)
  ,runPrivate
    ) where


import Control.DeepSeq (NFData)
import Control.Exception (Exception)
import Control.Lens (makeLenses)
import Control.Monad.Catch (MonadThrow, MonadCatch, throwM)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader
       (MonadReader(..), ReaderT(..), runReaderT)
import Control.Monad.State.Strict
       (MonadState(..), StateT(..), runStateT)
import Crypto.Noise (HandshakeRole(..), NoiseState)
import Crypto.Noise.Cipher (Cipher(..), AssocData)
import Crypto.Noise.Cipher.AESGCM (AESGCM)
import Crypto.Noise.DH (KeyPair, DH(..))
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

import Kadena.Types.Base (Alias(..))

import Pact.Types.Orphans ()
import Pact.Types.Util (AsString(..))

newtype EntityName = EntityName Text
  deriving (IsString,AsString,Eq,Ord,Hashable,Serialize,NFData)
instance Show EntityName where show (EntityName t) = show t

newtype Label = Label ByteString
  deriving (IsString,Eq,Ord,Hashable,Serialize,NFData,Monoid,ByteArray,ByteArrayAccess)
instance Show Label where show (Label l) = show (B16.encode l)
instance AsString Label where asString (Label l) = T.pack $ B8.unpack $ B16.encode l

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
makeLenses ''EntityLocal
instance Show EntityLocal where
  show EntityLocal{..} = show ("EntityLocal:" <> asString _elName)

data EntityRemote = EntityRemote {
    _erName :: EntityName
  , _erStatic :: PublicKey Curve25519
  }
makeLenses ''EntityRemote
instance Show EntityRemote where
  show EntityRemote{..} = show ("EntityRemote:" <> asString _erName)

data RemoteSession = RemoteSession {
    _rsName :: Text
  , _rsEntity :: EntityName
  , _rsNoise :: Noise
  , _rsRole :: HandshakeRole
  , _rsSendLabeler :: Labeler
  , _rsRecvLabeler :: Labeler
  , _rsLabel :: Label
  , _rsVersion :: Word64
  }
makeLenses ''RemoteSession
instance Show RemoteSession where
  show RemoteSession{..} =
    T.unpack (asString _rsName <> ",remote=" <>
              asString _rsEntity <> ",label=" <> asString _rsLabel <> ",v=") ++
    show _rsVersion

data EntitySession = EntitySession {
    _esInitNoise :: Noise
  , _esRespNoise :: Noise
  , _esLabeler :: Labeler
  , _esLabel :: Label
  , _esVersion :: Word64
  }
makeLenses ''EntitySession
instance Show EntitySession where
  show EntitySession{..} = show ("Entity=" <> asString _esLabel)


data Sessions = Sessions {
    _sEntity :: EntitySession
  , _sRemotes :: HM.HashMap EntityName RemoteSession
  , _sLabels :: HM.HashMap Label EntityName
  } deriving (Show)
makeLenses ''Sessions


data PrivateMessage = PrivateMessage {
    _pmFrom :: EntityName
  , _pmSender :: Alias
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
instance Show Labeled where
  show Labeled{..} = "label=" ++ show _lLabel ++ ",payload=" ++ show (B16.encode _lPayload)

data PrivateEnvelope = PrivateEnvelope {
    _peEntity :: Labeled
  , _peRemotes :: [Labeled]
  } deriving (Generic,Show)
instance Serialize PrivateEnvelope

data PrivateEnv = PrivateEnv {
    _entityLocal :: EntityLocal
  , _entityRemotes :: [EntityRemote]
  , _nodeAlias :: Alias
  } deriving (Show)
makeLenses ''PrivateEnv

data PrivateState = PrivateState {
      _sessions :: Sessions
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
