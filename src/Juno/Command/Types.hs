{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}

module Juno.Command.Types where

import Data.Default
import Data.Aeson as A
import Data.ByteString (ByteString)
import qualified Crypto.PubKey.Curve25519 as C2
import Data.ByteArray.Extend
import Data.Serialize as SZ hiding (get)
import GHC.Generics
import Control.Monad.State
import Control.Monad.Reader
import Control.Exception.Safe
import Data.Text.Encoding
import Control.Applicative
import Control.Lens hiding ((.=))
import Data.Maybe
import Text.Trifecta.Combinators (DeltaParsing(..))
import qualified Data.Attoparsec.Text as AP
import Prelude hiding (log,exp)
import Data.Text

import Pact.Types hiding (PublicKey)
import Pact.Pure

import Juno.Types.Log
import Juno.Types.Base hiding (Term)
import Juno.Types.Command



{-

RPC - plaintext command RPC.
SSK - shared symmetric key, which may be iterated as SSK', SSK'' ...
PSK - pre-shared key, identifying the node entity
SO - session object (NoiseState in cacophony, something else in n-way). Iterable.
ST - session tag. E.g., 12 zero-bytes encrypted with current SSK. Iterable.

Encryption Modes:
- None
- DisjointPlain: n-way encryption using plaintext identifiers, for simulating private interaction
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
    deriving (Eq,Generic)
instance FromJSON ExecMsg where
    parseJSON =
        withObject "PactMsg" $ \o ->
            ExecMsg <$> o .: "code" <*> o .: "data"
instance ToJSON ExecMsg where
    toJSON (ExecMsg c d) = object [ "code" .= c, "data" .= d]

data YieldMsg = YieldMsg {
      _ymTxId :: TxId
    , _ymStep :: Int
    , _ymRollback :: Bool
    }
    deriving (Eq)
instance FromJSON YieldMsg where
    parseJSON =
        withObject "YieldMsg" $ \o ->
            YieldMsg <$> o .: "txid" <*> o .: "step" <*> o .: "rollback"
instance ToJSON YieldMsg where
    toJSON (YieldMsg t s r) = object [ "txid" .= t, "step" .= s, "rollback" .= r]

data MultisigMsg = MultisigMsg {
      _mmTxId :: TxId
    } deriving (Eq)
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
      _pmPayload :: ByteString
    , _pmKey :: PublicKey
    , _pmSig :: Signature
    } deriving (Eq,Generic)
instance Serialize PactMessage

data PactRPC =
    Exec ExecMsg |
    Yield YieldMsg |
    Multisig MultisigMsg
    deriving (Eq)
instance FromJSON PactRPC where
    parseJSON =
        withObject "RPC" $ \o ->
            (Exec <$> o .: "exec") <|>
             (Yield <$> o .: "yield") <|>
             (Multisig <$> o .: "multisig")
instance ToJSON PactRPC where
    toJSON (Exec p) = object ["exec" .= p]
    toJSON (Yield p) = object ["yield" .= p]
    toJSON (Multisig p) = object ["multisig" .= p]

class ToRPC a where
    toRPC :: a -> PactRPC

instance ToRPC ExecMsg where toRPC = Exec
instance ToRPC YieldMsg where toRPC = Yield
instance ToRPC MultisigMsg where toRPC = Multisig


data EntityInfo = EntityInfo {
      _entName :: String
}
$(makeLenses ''EntityInfo)


data CommandConfig = CommandConfig {
      _ccEntity :: EntityInfo
    , _ccDebug :: String -> IO ()
    }
$(makeLenses ''CommandConfig)

data CommandState = CommandState {
      _csPactState :: PureState
    }
instance Default CommandState where def = CommandState def
$(makeLenses ''CommandState)


data ExecutionMode =
    Transactional { _emTxId :: TxId } |
    Local
    deriving (Eq,Show)
$(makeLenses ''ExecutionMode)

data CommandEnv = CommandEnv {
      _ceConfig :: CommandConfig
    , _ceMode :: ExecutionMode
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

instance DeltaParsing AP.Parser where
    line = return mempty
    position = return mempty
    slicedWith f a = a <&> (`f` mempty)
    rend = return mempty
    restOfLine = return mempty

type ApplyLogEntry = LogEntry -> IO CommandResult
type ApplyLocal = ByteString -> IO CommandResult

type CommandM a = ReaderT CommandEnv (StateT CommandState IO) a

runCommand :: CommandEnv -> CommandState -> CommandM a -> IO (a,CommandState)
runCommand e s a = runStateT (runReaderT a e) s


throwCmdEx :: MonadThrow m => String -> m a
throwCmdEx = throw . CommandException
