{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}

module Juno.Command.Types where

import Control.Concurrent
import Data.Default
import qualified Numeric as N
import Data.String
import qualified Data.Text as T
import Data.Aeson
import Data.Word
import GHC.Generics
import Data.ByteString (ByteString)
import Crypto.Noise
import qualified Crypto.PubKey.Curve25519 as C
import Control.Monad.Catch (MonadThrow (..))
import Data.ByteArray.Extend


import Pact.Types
import Pact.Pure

import Juno.Types.Base
import Juno.Types.Log
import Juno.Types.Command
import Juno.Types.Message




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

type EntSecretKey = C.SecretKey
type EntPublicKey = C.PublicKey

-- | Types of encryption sessions.
data SessionCipherType =
    -- | Not encrypted
    None |
    -- | Simulate n-way encryption
    DisjointPlain |
    -- | Two-way (noise)
    TwoWay |
    -- | N-way (TBD)
    NWay
    deriving (Eq,Show,Enum,Bounded,Generic)


data MessageTags =
    SessionInitTags { _mtInitTags :: [ByteString] } |
    SessionTag { _mtSessionTag :: ByteString }



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


{-



RPC messages:
- Transaction
- Local
- Yield
- Multisig

-}

type RPCPublicKey = C.PublicKey

data ExecutionMode = Transactional | Local deriving (Eq,Show)


data PactMsg = PactMsg {
      _pmCode :: String
    , _pmData :: Value
    , _pmMode :: ExecutionMode
    }

data YieldMsg = YieldMsg {
      _ymTxId :: TxId
    , _ymStep :: Int
    , _ymRollback :: Bool
    }

type RPCDigest = (RPCPublicKey,ByteString)

data RPC =
    Exec {
      _rPactMsg :: PactMsg
    , _rDigest :: RPCDigest
    } |
    Yield {
      _rYieldMsg :: YieldMsg
    , _rDigest :: RPCDigest
    } |
    Multisig {
      _rTxId :: TxId
    , _rDigest :: RPCDigest
    }










data PactCommand = PactCommand {
      _pcCode :: T.Text
    , _pcData :: Value
    } deriving (Eq,Show)



initPact :: IO (LogEntry -> IO CommandResult)
initPact = do
  mv <- newMVar def
  return $ \le ->
      do
        pactState <- takeMVar mv
        (s,r) <- runPact pactState le
        putMVar mv s
        return r

foo :: Command
foo = undefined

runPact :: PureState -> LogEntry -> IO (PureState,CommandResult)
runPact s e = undefined
    where logIndex = _leLogIndex e
          cmd = _leCommand e
          cmdEntry = _cmdEntry cmd


{-
LogEntry { _leTerm    :: !Term
  , _leLogIndex :: !LogIndex
  , _leCommand :: !Command
  , _leHash    :: !ByteString
  }


data Command = Command
  { _cmdEntry      :: !CommandEntry
  , _cmdClientId   :: !NodeId
  , _cmdRequestId  :: !RequestId
  , _cmdEncryptGroup :: !(Maybe Alias)
  , _cmdCryptoVerified :: !CryptoVerified
  , _cmdProvenance :: !Provenance
  }



newtype CommandEntry = CommandEntry { unCommandEntry :: ByteString }
  deriving (Show, Eq, Ord, Generic, Serialize)

newtype CommandResult = CommandResult { unCommandResult :: ByteString }
  deriving (Show, Eq, Ord, Generic, Serialize)
-}
