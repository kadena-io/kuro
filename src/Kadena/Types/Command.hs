{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Command
  ( CCPayload (..)
  , CCState (..)
  , ClusterChangeCommand (..), cccPayload, cccSigs, cccHash
  , ClusterChangeInfo (..), cciNewNodeList, cciAddedNodes, cciRemovedNodes, cciState
  , ClusterChangeResult (..)
  , Command(..), sccCmd, sccPreProc, cccCmd, cccPreProc, pcCmd
  , ConfigChangeApiReq(..)
  , Hashed(..)
  , Preprocessed(..)
  , RunPreProc(..)
  , FinishedPreProc(..)
  , PendingResult(..)
  , ProcessedClusterChg (..)
  , SCCPreProcResult, CCCPreProcResult
  , CMDWire(..)
  , CommandResult(..), crHash, crLogIndex, crLatMetrics
  , scrResult, concrResult, pcrResult
  , CmdLatencyMetrics(..), rlmFirstSeen, rlmHitTurbine, rlmHitConsensus, rlmFinConsensus, rlmAerConsensus, rlmLogConsensus
  , rlmHitPreProc, rlmFinPreProc, rlmHitExecution, rlmFinExecution
  , lmFirstSeen, lmHitTurbine, lmHitPreProc, lmAerConsensus, lmLogConsensus
  , lmFinPreProc, lmHitExecution, lmFinExecution, lmHitConsensus, lmFinConsensus
  , CmdLatASetter
  , CmdResultLatencyMetrics(..)
  , getCmdBodyHash
  ) where

import Control.Lens (ASetter, makeLenses)
import Control.Concurrent
import Control.DeepSeq
import Data.Serialize (Serialize)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Thyme.Clock
import Data.Thyme.Time.Core ()
import Data.Aeson
import GHC.Generics
import GHC.Int (Int64)

import Kadena.Types.Base
import Kadena.Private.Types (PrivateCiphertext,PrivateResult)

import qualified Pact.ApiReq as Pact
import qualified Pact.Types.Command as Pact
import qualified Pact.Types.RPC as Pact
import Pact.Types.Util

data CmdLatencyMetrics = CmdLatencyMetrics
  { _lmFirstSeen :: !UTCTime
  , _lmHitTurbine :: !(Maybe UTCTime)
  , _lmHitConsensus :: !(Maybe UTCTime)
  , _lmFinConsensus :: !(Maybe UTCTime)
  , _lmAerConsensus :: !(Maybe UTCTime)
  , _lmLogConsensus :: !(Maybe UTCTime)
  , _lmHitPreProc :: !(Maybe UTCTime)
  , _lmFinPreProc :: !(Maybe UTCTime)
  , _lmHitExecution :: !(Maybe UTCTime)
  , _lmFinExecution :: !(Maybe UTCTime)
  } deriving (Show, Eq, Ord, Generic)
makeLenses ''CmdLatencyMetrics
instance ToJSON CmdLatencyMetrics where
  toJSON = lensyToJSON 3
instance FromJSON CmdLatencyMetrics where
  parseJSON = lensyParseJSON 3

type CmdLatASetter a = ASetter CmdLatencyMetrics CmdLatencyMetrics a (Maybe UTCTime)

data PendingResult a = PendingResult
  { _prResult :: !a
  , _prStartedPreProc :: !(Maybe UTCTime)
  , _prFinishedPreProc :: !(Maybe UTCTime)
  }

data Preprocessed a =
  Unprocessed |
  Pending {pending :: !(MVar (PendingResult a))} |
  Result {result :: a}
  deriving (Eq, Generic)
instance (Show a) => Show (Preprocessed a) where
  show Unprocessed = "Unprocessed"
  show Pending{} = "Pending {unPending = <MVar>}"
  show (Result a) = "Result {unResult = " ++ show a ++ "}"

data CCState =
  Transitional |
  Final
  deriving (Show, Eq, Ord, Generic, Serialize)
instance ToJSON CCState where
instance FromJSON CCState where
instance NFData CCState

data ConfigChangeApiReq = ConfigChangeApiReq
  { _ylccInfo :: ClusterChangeInfo
  , _ylccKeyPairs :: ![Pact.KeyPair]
  , _ylccNonce :: Maybe String
  } deriving (Eq,Show,Generic)
instance ToJSON ConfigChangeApiReq where toJSON = lensyToJSON 5
instance FromJSON ConfigChangeApiReq where parseJSON = lensyParseJSON 5

data ClusterChangeInfo = ClusterChangeInfo
  { _cciNewNodeList :: ![NodeId]
  , _cciAddedNodes :: ![NodeId]
  , _cciRemovedNodes :: ![NodeId]
  , _cciState :: CCState }
  deriving (Show, Eq, Generic, Serialize)
makeLenses ''ClusterChangeInfo
instance NFData ClusterChangeInfo
instance ToJSON ClusterChangeInfo where
  toJSON = lensyToJSON 4
instance FromJSON ClusterChangeInfo where
  parseJSON = lensyParseJSON 4

data CCPayload = CCPayload
  { _ccpInfo :: !ClusterChangeInfo
  , _ccpNonce :: !Text
  } deriving (Show, Eq, Generic, Serialize)

instance NFData CCPayload
instance ToJSON CCPayload where toJSON = lensyToJSON 4
instance FromJSON CCPayload where parseJSON = lensyParseJSON 4

data ClusterChangeCommand a = ClusterChangeCommand
  { _cccPayload :: !a
  , _cccSigs :: ![Pact.UserSig]
  , _cccHash :: !Hash
  } deriving (Eq,Show,Ord,Generic,Functor)
makeLenses ''ClusterChangeCommand

instance (Serialize a) => Serialize (ClusterChangeCommand a)
instance (ToJSON a) => ToJSON (ClusterChangeCommand a) where
    toJSON (ClusterChangeCommand payload uSigs hsh) =
        object [ "cmd" .= payload
               , "sigs" .= toJSON uSigs
               , "hash" .= hsh
               ]
instance (FromJSON a) => FromJSON (ClusterChangeCommand a) where
    parseJSON = withObject "Command" $ \o ->
      ClusterChangeCommand <$> (o .: "cmd")
                           <*> (o .: "sigs" >>= parseJSON)
                           <*> (o .: "hash")
    {-# INLINE parseJSON #-}

instance NFData a => NFData (ClusterChangeCommand a)

data ProcessedClusterChg a =
  ProcClusterChgSucc
    !(ClusterChangeCommand a) |
  ProcClusterChgFail !String
  deriving (Show, Eq, Generic, Serialize)
instance NFData a => NFData (ProcessedClusterChg a)

type SCCPreProcResult = PendingResult (Pact.ProcessedCommand (Pact.PactRPC Pact.ParsedCode))
type CCCPreProcResult = PendingResult (ProcessedClusterChg CCPayload)

data RunPreProc =
  RunSCCPreProc
    { _rpSccRaw :: !(Pact.Command ByteString)
    , _rpSccMVar :: !(MVar SCCPreProcResult) } |
  RunCCCPreProc
    { _rpCccRaw :: !(ClusterChangeCommand ByteString)
    , _rpCccMVar :: !(MVar CCCPreProcResult) }

data FinishedPreProc =
  FinishedPreProcSCC
    { _fppSccRes :: !(Pact.ProcessedCommand (Pact.PactRPC Pact.ParsedCode))
    , _fppSccMVar :: !(MVar SCCPreProcResult)} |
  FinishedPreProcCCC
    { _fppCccRes :: !(ProcessedClusterChg CCPayload)
    , _fppCccMVar :: !(MVar CCCPreProcResult)}

instance NFData FinishedPreProc where
  rnf FinishedPreProcSCC{..} = case _fppSccRes of
    Pact.ProcSucc s -> rnf s
    Pact.ProcFail e -> rnf e
  rnf FinishedPreProcCCC{..} = case _fppCccRes of
    ProcClusterChgSucc cmd -> rnf cmd
    ProcClusterChgFail e -> rnf e

data Hashed a = Hashed
  { _hValue :: !a
  , _hHash :: !Hash
  } deriving (Show,Eq,Generic)
instance Serialize a => Serialize (Hashed a)
instance NFData a => NFData (Hashed a)

data Command =
  SmartContractCommand
  { _sccCmd :: !(Pact.Command ByteString)
  , _sccPreProc :: !(Preprocessed (Pact.ProcessedCommand (Pact.PactRPC Pact.ParsedCode))) } |
  ConsensusChangeCommand
  { _cccCmd :: !(ClusterChangeCommand ByteString)
  , _cccPreProc :: !(Preprocessed (ProcessedClusterChg CCPayload))} |
  PrivateCommand
  { _pcCmd :: !(Hashed PrivateCiphertext)
  }
  deriving (Show, Eq, Generic)
makeLenses ''Command

instance Ord Command where
  compare a b = compare (getCmdBodyHash a) (getCmdBodyHash b)

data ClusterChangeResult =
  ClusterChangeFailure !String
  | ClusterChangeSuccess
  deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON, Serialize)

getCmdBodyHash :: Command -> Hash
getCmdBodyHash SmartContractCommand{ _sccCmd = Pact.Command{..}} = _cmdHash
getCmdBodyHash ConsensusChangeCommand{ _cccCmd = ClusterChangeCommand{..}} = _cccHash
getCmdBodyHash PrivateCommand { _pcCmd = Hashed{..}} = _hHash

data CMDWire =
  SCCWire !ByteString |
  CCCWire !ByteString |
  PCWire !ByteString
  deriving (Show, Eq, Generic)
instance Serialize CMDWire

data CmdResultLatencyMetrics = CmdResultLatencyMetrics
  { _rlmFirstSeen :: !UTCTime
  , _rlmHitTurbine :: !(Maybe Int64)
  , _rlmHitConsensus :: !(Maybe Int64)
  , _rlmFinConsensus :: !(Maybe Int64)
  , _rlmAerConsensus :: !(Maybe Int64)
  , _rlmLogConsensus :: !(Maybe Int64)
  , _rlmHitPreProc :: !(Maybe Int64)
  , _rlmFinPreProc :: !(Maybe Int64)
  , _rlmHitExecution :: !(Maybe Int64)
  , _rlmFinExecution :: !(Maybe Int64)
  } deriving (Show, Eq, Ord, Generic)
makeLenses ''CmdResultLatencyMetrics

instance ToJSON CmdResultLatencyMetrics where
  toJSON = lensyToJSON 4
instance FromJSON CmdResultLatencyMetrics where
  parseJSON = lensyParseJSON 4

data CommandResult =
  SmartContractResult
    { _crHash :: !Hash
    , _scrResult :: !Pact.CommandResult
    , _crLogIndex :: !LogIndex
    , _crLatMetrics :: !(Maybe CmdResultLatencyMetrics) } |
   ConsensusChangeResult
    { _crHash :: !Hash
    , _concrResult :: !ClusterChangeResult
    , _crLogIndex :: !LogIndex
    , _crLatMetrics :: !(Maybe CmdResultLatencyMetrics) } |
  PrivateCommandResult
    { _crHash :: !Hash
    , _pcrResult :: !(PrivateResult Pact.CommandResult)
    , _crLogIndex :: !LogIndex
    , _crLatMetrics :: !(Maybe CmdResultLatencyMetrics) }
  deriving (Show, Eq, Generic)
makeLenses ''CommandResult
