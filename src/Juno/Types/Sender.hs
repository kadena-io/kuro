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

module Juno.Types.Sender
  ( SenderServiceChannel(..)
  , ServiceRequest(..)
  , Update(..)
  , AEBroadcastControl(..)
  , SenderService
  , SenderServiceState(..), myNodeId, currentLeader, currentTerm, myPublicKey
  , myPrivateKey, yesVotes, debugPrint, serviceRequestChan, outboundGeneral, outboundAerRvRvr
  , logThread, otherNodes, nodeRole
  ) where

import Control.Lens
-- import Control.Monad
import Control.Concurrent (MVar)
import Control.Monad.Trans.State.Strict (StateT)

import qualified Control.Concurrent.Chan.Unagi.NoBlocking as NoBlock

import Data.Map (Map)
import Data.Set (Set)
import Data.IORef


import Juno.Types.Log
import Juno.Types.Base
import Juno.Types.Message
import Juno.Types.Comms


newtype SenderServiceChannel =
  SenderServiceChannel (NoBlock.InChan ServiceRequest, MVar (NoBlock.Stream ServiceRequest))

instance Comms ServiceRequest SenderServiceChannel where
  initComms = SenderServiceChannel <$> initCommsNoBlock
  readComm (SenderServiceChannel (_,o)) = readCommNoBlock o
  readComms (SenderServiceChannel (_,o)) = readCommsNoBlock o
  writeComm (SenderServiceChannel (i,_)) = writeCommNoBlock i


data AEBroadcastControl =
  SendAERegardless |
  OnlySendIfFollowersAreInSync |
  SendEmptyAEIfOutOfSync
  deriving (Show, Eq)

data ServiceRequest =
    SingleAE
    { _srFor :: !NodeId
    , _srNextIndex :: !(Maybe LogIndex)
    , _srFollowsLeader :: !Bool} |
    BroadcastAE
    { _srAeBoardcastControl :: !AEBroadcastControl
    , _srlNextIndex :: !(Map NodeId LogIndex)
    , _srConvincedNodes :: !(Set NodeId) } |
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
    , _srCommands :: [Command]} |
    UpdateState [Update]
    deriving (Eq, Show)

data Update where
  Update :: forall a . Lens' SenderServiceState a -> a -> Update

instance Eq Update where
  (==) _ _ = False

instance Show Update where
  show (Update _ _) = "<state updates>"

data SenderServiceState = SenderServiceState
  { _myNodeId :: !NodeId
  , _nodeRole :: !Role
  , _otherNodes :: !(Set NodeId)
  , _currentLeader :: !(Maybe NodeId)
  , _currentTerm :: !Term
  , _myPublicKey :: !PublicKey
  , _myPrivateKey :: !PrivateKey
  , _yesVotes :: !(Set RequestVoteResponse)
  , _debugPrint :: (String -> IO ())
  -- Comm Channels
  , _serviceRequestChan :: SenderServiceChannel
  , _outboundGeneral :: OutboundGeneralChannel
  , _outboundAerRvRvr :: OutboundAerRvRvrChannel
  -- Log Storage
  , _logThread :: IORef (LogState LogEntry)
  }
makeLenses ''SenderServiceState

type SenderService = StateT SenderServiceState IO
