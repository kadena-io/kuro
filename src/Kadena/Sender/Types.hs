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

module Kadena.Sender.Types
  ( SenderServiceChannel(..)
  , ServiceRequest'(..)
  , ServiceRequest(..)
  , StateSnapshot(..), newNodeId, newRole, newOtherNodes, newLeader, newTerm, newPublicKey
  , newPrivateKey, newYesVotes
  , AEBroadcastControl(..)
  ) where

import Control.Lens
import Control.Concurrent.Chan (Chan)

import Data.Set (Set)
import Data.Thyme.Clock

import Kadena.Types.Base
import Kadena.Types.Message
import Kadena.Types.Comms

import Kadena.Types.Event (Beat)

data ServiceRequest' =
  ServiceRequest'
  { _unSS :: StateSnapshot
  , _unSR :: ServiceRequest } |
  ForwardCommandToLeader
  { _srCommands :: !NewCmdRPC} |
  SendAllAppendEntriesResponse
  { _srLastLogHash :: !LogIndex
  , _srMaxIndex :: !Hash
  , _srIssuedTime :: !UTCTime} |
  Heart Beat
  deriving (Eq, Show)

newtype SenderServiceChannel = SenderServiceChannel (Chan ServiceRequest')

instance Comms ServiceRequest' SenderServiceChannel where
  initComms = SenderServiceChannel <$> initCommsNormal
  readComm (SenderServiceChannel c) = readCommNormal c
  writeComm (SenderServiceChannel c) = writeCommNormal c

data AEBroadcastControl =
  SendAERegardless -- ^ Causes an AE to be sent no matter what. Use with care, under load we don't want to send > 1 replication AE per heartbeat period
  | OnlySendIfFollowersAreInSync -- ^ Only dispatches the AE if follower are all in sync (steady state) AND if the last AE to replicate entries was > 1 HB Timeout ago
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
    BroadcastAER | -- TODO: verify that we did ^ and this can be removed
    BroadcastRV RequestVote|
    BroadcastRVR
    { _srCandidate :: !NodeId
    , _srHeardFromLeader :: !(Maybe HeardFromLeader)
    , _srVote :: !Bool}
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
