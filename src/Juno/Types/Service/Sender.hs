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
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Juno.Types.Service.Sender
  ( SenderServiceChannel(..)
  , ServiceRequest'(..)
  , ServiceRequest(..)
  , StateSnapshot(..), newNodeId, newRole, newOtherNodes, newLeader, newTerm, newPublicKey
  , newPrivateKey, newYesVotes, aeReplicationLogLimit
  , AEBroadcastControl(..)
  , SenderService
  , ServiceEnv(..), myNodeId, currentLeader, currentTerm, myPublicKey
  , myPrivateKey, yesVotes, debugPrint, serviceRequestChan, outboundGeneral, outboundAerRvRvr
  , logService, otherNodes, nodeRole, getEvidenceState
  ) where

import Control.Lens
-- import Control.Monad
import Control.Concurrent (MVar)
import Control.Monad.Trans.Reader (ReaderT)

import qualified Control.Concurrent.Chan.Unagi as Unagi

import Data.Set (Set)

import Juno.Types.Base
import Juno.Types.Message
import Juno.Types.Comms
import Juno.Types.Service.Log (LogServiceChannel)
import Juno.Types.Service.Evidence (PublishedEvidenceState)

data ServiceRequest' =
  ServiceRequest'
    { _unSS :: StateSnapshot
    , _unSR :: ServiceRequest } |
  Tick Tock
  deriving (Eq, Show)

newtype SenderServiceChannel =
  SenderServiceChannel (Unagi.InChan ServiceRequest', MVar (Maybe (Unagi.Element ServiceRequest', IO ServiceRequest'), Unagi.OutChan ServiceRequest'))

instance Comms ServiceRequest' SenderServiceChannel where
  initComms = SenderServiceChannel <$> initCommsUnagi
  readComm (SenderServiceChannel (_,o)) = readCommUnagi o
  readComms (SenderServiceChannel (_,o)) = readCommsUnagi o
  writeComm (SenderServiceChannel (i,_)) = writeCommUnagi i

data AEBroadcastControl =
  SendAERegardless |
  OnlySendIfFollowersAreInSync
  deriving (Show, Eq)

data ServiceRequest =
    BroadcastAE
    { _srAeBoardcastControl :: !AEBroadcastControl } |
    SingleAER
    { _srFor :: !NodeId
    , _srSuccess :: !Bool
    , _srConvinced :: !Bool }|
    -- TODO: we can be smarter here and fill in the details the AER needs about the logs without needing to hit that thread
    BroadcastAER |
    BroadcastRV |
    BroadcastRVR
    { _srCandidate :: !NodeId
    , _srLastLogIndex :: !LogIndex
    , _srVote :: !Bool} |
    SendCommandResults
    { _srResults :: ![(NodeId, CommandResponse)]} |
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
  , _debugPrint :: (String -> IO ())
  , _aeReplicationLogLimit :: Int
  -- Comm Channels
  , _serviceRequestChan :: SenderServiceChannel
  , _outboundGeneral :: OutboundGeneralChannel
  , _outboundAerRvRvr :: OutboundAerRvRvrChannel
  -- Log Storage
  , _logService :: LogServiceChannel
  -- Evidence Thread's Published State
  , _getEvidenceState :: IO PublishedEvidenceState
  }
makeLenses ''ServiceEnv

type SenderService = ReaderT ServiceEnv IO
