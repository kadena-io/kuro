{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.ConfigChange.Types
  ( ConfigChangeService
  , ConfigChangeState(..)
  , ConfigUpdate(..)     
  , ConfigUpdateCommand(..)
  , ConfigUpdater(..)   
  , ConfigUpdateResult(..)
  , cuCmd, cuHash, cuSigs
  , DiffNodes(..)
  , NodesToDiff(..)
  , ProcessedConfigUpdate(..)
  ) where

import Control.Concurrent.Chan (Chan)    
import Control.Lens (makeLenses)
import Control.Monad.Trans.RWS.Lazy
import Data.Aeson
import Data.Map (Map)
import Data.Set (Set)
import Data.Serialize
import GHC.Generics
import Kadena.Types.Base
import Kadena.Types.Comms
import Kadena.Types.Config
import Pact.Types.Util

{-
data Evidence =
  -- * A list of verified AER's, the turbine handles the crypto
  VerifiedAER { _unVerifiedAER :: [AppendEntriesResponse]} |
  -- * When we verify a new leader, become a candidate or become leader we need to clear out
  -- the set of convinced nodes. SenderService.BroadcastAE needs this info for attaching votes
  -- to the message
  ClearConvincedNodes |
  -- * The LogService has a pretty good idea of what hashes we'll need to check and can pre-cache
  -- them with us here. Log entries come in batches and AER's are only issued pertaining to the last.
  -- So, whenever LogService sees a new batch come it, it hands us the info for the last one.
  -- We will have misses -- if nodes are out of sync they may get different batches but overall this should
  -- function fine.
  CacheNewHash { _cLogIndex :: LogIndex , _cHash :: Hash } |
  Bounce | -- TODO: change how config changes are handled so we don't use bounce
  Heart Beat
  deriving (Show, Eq, Typeable)
-}
--or
{-
data Execution =
  ReloadFromDisk
    { logEntriesToApply :: !LogEntries } |
  ExecuteNewEntries
    { logEntriesToApply :: !LogEntries } |
  ChangeNodeId
    { newNodeId :: !NodeId } |
  UpdateKeySet
    { newKeySet :: !KeySet } |
  Heart Beat |
  ExecLocal
    { localCmd :: !(Pact.Command ByteString),
      localResult :: !(MVar Value) }
-}
data ConfigChange = SomeDataA Int | SomeDataB Int

newtype ConfigChangeChannel = ConfigChangeChannel (Chan ConfigChange)

instance Comms ConfigChange ConfigChangeChannel where
  initComms = ConfigChangeChannel <$> initCommsNormal
  readComm (ConfigChangeChannel c) = readCommNormal c
  writeComm (ConfigChangeChannel c) = writeCommNormal c

data ConfigChangeEnv = ConfigChangeEnv
  { _cceTbd :: !Int
  } deriving (Show, Eq)
makeLenses ''ConfigChangeEnv
{-
data EvidenceEnv = EvidenceEnv
  { _logService :: !LogServiceChannel
  , _evidence :: !EvidenceChannel
  , _mResetLeaderNoFollowers :: !(MVar ResetLeaderNoFollowersTimeout)
  , _mConfig :: !(GlobalConfigTMVar)
  , _mPubStateTo :: !(MVar PublishedEvidenceState)
  , _debugFn :: !(String -> IO ())
  , _publishMetric :: !(Metric -> IO ())
  }
-}

type ConfigChangeService s = RWST ConfigChangeEnv () s IO

data ConfigChangeState = ConfigChangeState
  { _cssTbd :: !Int
  } deriving (Show, Eq)
makeLenses ''ConfigChangeState
{-
data EvidenceState = EvidenceState
  { _esOtherNodes :: !(Set NodeId)
  , _esQuorumSize :: !Int
  , _esNodeStates :: !(Map NodeId (LogIndex, UTCTime))
  , _esConvincedNodes :: !(Set NodeId)
  , _esPartialEvidence :: !(Map LogIndex Int)
  , _esCommitIndex :: !LogIndex
  , _esMaxCachedIndex :: !LogIndex
  , _esCacheMissAers :: !(Set AppendEntriesResponse)
  , _esMismatchNodes :: !(Set NodeId)
  , _esResetLeaderNoFollowers :: Bool
  , _esHashAtCommitIndex :: !Hash
  , _esEvidenceCache :: !(Map LogIndex Hash)
  , _esMaxElectionTimeout :: !Int
  } deriving (Show, Eq)
-}

data ConfigUpdateCommand =
    AddNode
      { _cucNodeId :: !NodeId
      , _cucNodeClass :: !NodeClass
      , _cucPublicKey :: !PublicKey } |
    RemoveNode
      { _cucNodeId :: !NodeId } |
    NodeToPassive
      { _cucNodeId :: !NodeId } |
    NodeToActive
      { _cucNodeId :: !NodeId } |
    UpdateNodeKey
      { _cucAlias :: !Alias
      , _cucPublicKey :: !PublicKey
      , _cucKeyPairPath :: !FilePath} |
    AddAdminKey
      { _cucAlias :: !Alias
      , _cucPublicKey :: !PublicKey } |
    UpdateAdminKey
      { _cucAlias :: !Alias
      , _cucPublicKey :: !PublicKey } |
    RemoveAdminKey
      { _cucAlias :: !Alias } |
    RotateLeader
      { _cucTerm :: !Term }
    deriving (Show, Eq, Ord, Generic, Serialize)

instance ToJSON ConfigUpdateCommand where
  toJSON = genericToJSON (confUpdateJsonOptions 4)
instance FromJSON ConfigUpdateCommand where
  parseJSON = genericParseJSON (confUpdateJsonOptions 4)

data ConfigUpdate a = ConfigUpdate
  { _cuHash :: !Hash
  , _cuSigs :: !(Map PublicKey Signature)
  , _cuCmd :: !a
  } deriving (Show, Eq, Ord, Generic, Serialize)
makeLenses ''ConfigUpdate

instance (ToJSON a) => ToJSON (ConfigUpdate a) where
  toJSON = lensyToJSON 3
instance (FromJSON a) => FromJSON (ConfigUpdate a) where
  parseJSON = lensyParseJSON 3

data ConfigUpdater = ConfigUpdater
  { _cuPrintFn :: !(String -> IO ())
  , _cuThreadName :: !String
  , _cuAction :: (Config -> IO())}

data ProcessedConfigUpdate =
  ProcessedConfigFailure !String |
  ProcessedConfigSuccess { _pcsRes :: !ConfigUpdateCommand
                         , _pcsKeysUsed :: !(Set PublicKey)}
  deriving (Show, Eq, Ord, Generic)

data ConfigUpdateResult =
  ConfigUpdateFailure !String
  | ConfigUpdateSuccess
  deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON, Serialize)

data NodesToDiff = NodesToDiff
  { prevNodes :: !(Set NodeId)
  , currentNodes :: !(Set NodeId)
  } deriving (Show,Eq,Ord,Generic)

data DiffNodes = DiffNodes
  { nodesToAdd :: !(Set NodeId)
  , nodesToRemove :: !(Set NodeId)
  } deriving (Show,Eq,Ord,Generic)
