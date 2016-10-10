{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}

module Kadena.Command.Types where

import Data.Aeson as A
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BSL
import qualified Crypto.PubKey.Curve25519 as C2
import Data.ByteArray.Extend
import Data.Serialize as SZ hiding (get)
import GHC.Generics
import Control.Monad.Reader
import Control.Exception.Safe
import Data.Text
import Data.Text.Encoding
import Control.Applicative
import Control.Lens hiding ((.=))
import Data.Maybe
import Prelude hiding (log,exp)
import Control.Concurrent.MVar

import Pact.Types hiding (PublicKey)
import Pact.Pure

import Kadena.Command.PactSqlLite

import Kadena.Types.Base hiding (Term)
import Kadena.Types.Command
import Kadena.Types.Config


type EntSecretKey = C2.SecretKey
type EntPublicKey = C2.PublicKey


-- | Types of encryption sessions.
data SessionCipherType =
    -- | Simulate n-way encryption
    DisjointPlain |
    -- | Two-way (noise)
    TwoWay |
    -- | N-way (TBD)
    NWay
    deriving (Eq,Show,Generic)
instance Serialize SessionCipherType

data MessageTags =
    SessionInitTags { _mtInitTags :: [ByteString] } |
    SessionTag { _mtSessionTag :: ByteString }
               deriving (Eq,Generic)
instance Serialize MessageTags



data CommandMessage =
    PublicMessage {
      _cmMessage :: ByteString
    } |
    PrivateMessage {
      _cmType :: SessionCipherType
    , _cmTags :: MessageTags
    , _cmMessage :: ByteString
    } deriving (Eq,Generic)
instance Serialize CommandMessage


-- | Encryption session message.
data SessionMessage =
    SessionMessage {
      _smTags :: MessageTags
    , _smMessage :: ByteString
    }


-- | Typeclass to abstract symmetric encryption operations.
class SessionCipher a where
    data SessionObject a :: *
    data SessionStore a :: *
    decryptInitTag :: EntSecretKey -> ByteString -> Maybe (SessionObject a)
    encryptInitTag :: proxy a -> EntPublicKey -> ByteString
    storeSessionObject :: SessionStore a -> SessionObject a -> ()
    retrieveSessionObject :: SessionStore a -> ByteString -> Maybe (SessionObject a)
    encryptMessage :: MonadThrow m => SessionObject a -> ScrubbedBytes -> m (ByteString,SessionObject a)
    decryptMessage :: MonadThrow m => SessionObject a -> ByteString -> m (ScrubbedBytes,SessionObject a)

data ExecMsg = ExecMsg {
      _pmCode :: Text
    , _pmData :: Value
    }
    deriving (Eq,Generic,Show)
instance FromJSON ExecMsg where
    parseJSON =
        withObject "PactMsg" $ \o ->
            ExecMsg <$> o .: "code" <*> o .: "data"
instance ToJSON ExecMsg where
    toJSON (ExecMsg c d) = object [ "code" .= c, "data" .= d]

data ContMsg = ContMsg {
      _cmTxId :: TxId
    , _cmStep :: Int
    , _cmRollback :: Bool
    }
    deriving (Eq,Show)
instance FromJSON ContMsg where
    parseJSON =
        withObject "ContMsg" $ \o ->
            ContMsg <$> o .: "txid" <*> o .: "step" <*> o .: "rollback"
instance ToJSON ContMsg where
    toJSON (ContMsg t s r) = object [ "txid" .= t, "step" .= s, "rollback" .= r]

data MultisigMsg = MultisigMsg {
      _mmTxId :: TxId
    } deriving (Eq,Show)
instance FromJSON MultisigMsg where
    parseJSON =
        withObject "MultisigMsg" $ \o ->
            MultisigMsg <$> o .: "txid"
instance ToJSON MultisigMsg where
    toJSON (MultisigMsg t) = object [ "txid" .= t]

data RPCDigest = RPCDigest {
      _rdPublicKey :: ByteString
    , _rdSignature :: ByteString
    } deriving (Eq)
instance FromJSON RPCDigest where
    parseJSON =
        withObject "RPCDigest" $ \o ->
            RPCDigest <$> fmap encodeUtf8 (o .: "key") <*> fmap encodeUtf8 (o .: "sig")

data PactMessage = PactMessage {
      _pmEnvelope :: ByteString
    , _pmKey :: PublicKey
    , _pmSig :: Signature
    , _pmHsh :: Hash
    } deriving (Eq,Generic)
instance Serialize PactMessage
instance ToJSON PactMessage where
    toJSON (PactMessage payload pk (Sig s) hsh) =
        object [ "env" .= decodeUtf8 payload
               , "key" .= pk
               , "sig" .= toB16JSON s
               , "hsh" .= hsh
               ]
instance FromJSON PactMessage where
    parseJSON = withObject "PactMessage" $ \o ->
                PactMessage <$> (encodeUtf8 <$> o .: "env")
                            <*> o .: "key"
                            <*> (o .: "sig" >>= \t -> Sig <$> parseB16JSON t)
                            <*> (o .: "hsh")

mkPactMessage :: ToJSON a => PrivateKey -> PublicKey -> Alias -> String -> a -> PactMessage
mkPactMessage sk pk al rid a = mkPactMessage' sk pk $ BSL.toStrict $ A.encode (PactEnvelope a rid al)
-- al rid (BSL.toStrict $ A.encode a)

mkPactMessage' :: PrivateKey -> PublicKey -> ByteString -> PactMessage
mkPactMessage' sk pk env = PactMessage env pk sig hsh
  where
    hsh = hash env
    sig = sign hsh sk pk

data PactEnvelope a = PactEnvelope {
      _pePayload :: a
    , _peRequestId :: String
    , _peAlias :: Alias
} deriving (Eq)
instance (ToJSON a) => ToJSON (PactEnvelope a) where
    toJSON (PactEnvelope r rid al) = object [ "payload" .= r,
                                              "rid" .= rid,
                                              "alias" .= al ]
instance (FromJSON a) => FromJSON (PactEnvelope a) where
    parseJSON = withObject "PactEnvelope" $ \o ->
                    PactEnvelope <$> o .: "payload"
                                     <*> o .: "rid"
                                     <*> o .: "alias"

data PactRPC =
    Exec ExecMsg |
    Continuation ContMsg |
    Multisig MultisigMsg
    deriving (Eq,Show)
instance FromJSON PactRPC where
    parseJSON =
        withObject "RPC" $ \o ->
            (Exec <$> o .: "exec") <|>
             (Continuation <$> o .: "yield") <|>
             (Multisig <$> o .: "multisig")
instance ToJSON PactRPC where
    toJSON (Exec p) = object ["exec" .= p]
    toJSON (Continuation p) = object ["yield" .= p]
    toJSON (Multisig p) = object ["multisig" .= p]

class ToRPC a where
    toRPC :: a -> PactRPC

instance ToRPC ExecMsg where toRPC = Exec
instance ToRPC ContMsg where toRPC = Continuation
instance ToRPC MultisigMsg where toRPC = Multisig



data CommandConfig = CommandConfig {
      _ccEntity :: EntityInfo
    , _ccDbFile :: Maybe FilePath
    , _ccDebugFn :: String -> IO ()
    }
$(makeLenses ''CommandConfig)

data CommandState = CommandState {
     _csRefStore :: RefStore
    }
$(makeLenses ''CommandState)


data ExecutionMode =
    Transactional { _emTxId :: TxId } |
    Local
    deriving (Eq,Show)
$(makeLenses ''ExecutionMode)


data DBVar = PureVar (MVar PureState) |
             PSLVar (MVar PSL)

data CommandEnv = CommandEnv {
      _ceConfig :: CommandConfig
    , _ceMode :: ExecutionMode
    , _ceDBVar :: DBVar
    , _ceState :: MVar CommandState
    }
$(makeLenses ''CommandEnv)

data CommandException = CommandException String
                        deriving (Typeable)
instance Show CommandException where show (CommandException e) = e
instance Exception CommandException

data CommandError = CommandError {
      _ceMsg :: String
    , _ceDetail :: Maybe String
}
instance ToJSON CommandError where
    toJSON (CommandError m d) =
        object $ [ "status" .= ("Failure" :: String)
                 , "msg" .= m ] ++
        maybe [] ((:[]) . ("detail" .=)) d

data CommandSuccess a = CommandSuccess {
      _csData :: a
    }
instance (ToJSON a) => ToJSON (CommandSuccess a) where
    toJSON (CommandSuccess a) =
        object [ "status" .= ("Success" :: String)
               , "result" .= a ]

type ApplyLocal = ByteString -> IO CommandResult

type CommandM a = ReaderT CommandEnv IO a

runCommand :: CommandEnv -> CommandM a -> IO a
runCommand e a = runReaderT a e


throwCmdEx :: MonadThrow m => String -> m a
throwCmdEx = throw . CommandException



{-

RPC - plaintext command RPC.
SSK - shared symmetric key, which may be iterated as SSK', SSK'' ...
PSK - pre-shared key, identifying the node entity
SO - session object (NoiseState in cacophony, something else in n-way). Iterable.
ST - session tag. E.g., 12 zero-bytes encrypted with current SSK. Iterable.

Encryption Modes:
- None
- Plain: n-way encryption using plaintext identifiers, for simulating private interaction
- TwoWay: two-way encryption using Noise.
- NWay: 3 or greater-way encryption TBD.

Encrypted message handling:

1. ByteBuffer received. Switch on mode:
 a. None: proceed to deserializing RPC.
 b. [Any other mode]: determine message type and handle.
   i. Session init + encrypted message: do Session Init (2).
   ii. Just encrypted message. Decrypt (3).
2. Session Init.
 Session init bundles a normal encrypted message for a session with a header containing
 one or more dummy messages. On receipt of any session init message recipient must try
 to decrypt dummy messages; success indicates that the recipient will be able to treat
 the bundled transaction message as a first-message in a normal session, and decrypt it.
3. Decryption.
 a. Determine session (if new session skip this step).
    Session tag (ST) will accompany payload ciphertext which is used to look up SO in store.
 b. Use SO to decrypt RPC, producing SO'.
 c. Encrypt ST for SO, ST' for SO' and use these ciphertexts to index SO, SO' in store.
 d. Expire old SOs as necessary.
 e. Deserialize RPC.

-}
