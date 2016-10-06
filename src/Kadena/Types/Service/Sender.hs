{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Kadena.Types.Service.Sender
  ( SenderServiceChannel(..)
  , ServiceRequest'(..)
  , ServiceRequest(..)
  , StateSnapshot(..), newNodeId, newRole, newOtherNodes, newLeader, newTerm, newPublicKey
  , newPrivateKey, newYesVotes, aeReplicationLogLimit
  , AEBroadcastControl(..)
  , SenderService
  , ServiceEnv(..), myNodeId, currentLeader, currentTerm, myPublicKey
  , myPrivateKey, yesVotes, debugPrint, serviceRequestChan, outboundGeneral, outboundAerRvRvr
  , logService, otherNodes, nodeRole, getEvidenceState, publishMetric
  ) where

import Control.Lens
import Control.Monad.Trans.Reader (ReaderT)
import Control.Concurrent.Chan (Chan)

import Data.Set (Set)

import Kadena.Types.Base
import Kadena.Types.Metric
import Kadena.Types.Message
import Kadena.Types.Comms
import Kadena.Log.Types (LogServiceChannel)
import Kadena.Types.Service.Evidence (PublishedEvidenceState)

data ServiceRequest' =
  ServiceRequest'
    { _unSS :: StateSnapshot
    , _unSR :: ServiceRequest } |
  Tick Tock
  deriving (Eq, Show)

newtype SenderServiceChannel = SenderServiceChannel (Chan ServiceRequest')

instance Comms ServiceRequest' SenderServiceChannel where
  initComms = SenderServiceChannel <$> initCommsNormal
  readComm (SenderServiceChannel c) = readCommNormal c
  writeComm (SenderServiceChannel c) = writeCommNormal c

data AEBroadcastControl =
  SendAERegardless |
  OnlySendIfFollowersAreInSync
  deriving (Show, Eq)

data ServiceRequest =
    BroadcastAE
    { _srAeBoardcastControl :: !AEBroadcastControl } |
    EstablishDominance |
    SingleAER
    { _srFor :: !NodeId
    , _srSuccess :: !Bool
    , _srConvinced :: !Bool }|
    -- TODO: we can be smarter here and fill in the details the AER needs about the logs without needing to hit that thread
    BroadcastAER |
    BroadcastRV RequestVote|
    BroadcastRVR
    { _srCandidate :: !NodeId
    , _srHeardFromLeader :: !(Maybe HeardFromLeader)
    , _srVote :: !Bool} |
    ForwardCommandToLeader
    { _srFor :: !NodeId
    , _srCommands :: [Command]}
    deriving (Eq, Show)

data StateSnapshot = StateSnapshot
  { _newNodeId :: !NodeId
  , _newRole :: !Role
  , _newOtherNodes :: !(Set NodeId)
  , _newLeader :: !(Maybe NodeId)
  , _newTerm :: !Term
  , _newPublicKey :: !PublicKey
  , _newPrivateKey :: !PrivateKey
  , _newYesVotes :: !(Set RequestVoteResponse)
  } deriving (Eq, Show)
makeLenses ''StateSnapshot

data ServiceEnv = ServiceEnv
  { _myNodeId :: !NodeId
  , _nodeRole :: !Role
  , _otherNodes :: !(Set NodeId)
  , _currentLeader :: !(Maybe NodeId)
  , _currentTerm :: !Term
  , _myPublicKey :: !PublicKey
  , _myPrivateKey :: !PrivateKey
  , _yesVotes :: !(Set RequestVoteResponse)
  , _debugPrint :: !(String -> IO ())
  , _aeReplicationLogLimit :: Int
  -- Comm Channels
  , _serviceRequestChan :: !SenderServiceChannel
  , _outboundGeneral :: !OutboundGeneralChannel
  , _outboundAerRvRvr :: !OutboundAerRvRvrChannel
  -- Log Storage
  , _logService :: !LogServiceChannel
  -- Evidence Thread's Published State
  , _getEvidenceState :: !(IO PublishedEvidenceState)
  , _publishMetric :: !(Metric -> IO ())
  }
makeLenses ''ServiceEnv

type SenderService = ReaderT ServiceEnv IO
