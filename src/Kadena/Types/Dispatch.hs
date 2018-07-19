{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Dispatch
  ( Dispatch(..)
  , initDispatch
  , dispInboundAER
  , dispInboundCMD
  , dispInboundRVorRVR
  , dispInboundGeneral
  , dispOutboundGeneral
  , dispConsensusEvent
  , dispSenderService
  , dispLogService
  , dispEvidence
  , dispExecService
  , dispHistoryChannel
  , dispProcessRequestChannel
  , dispPrivateChannel
  ) where

import Control.Lens

import Data.Typeable

import Kadena.Types.Comms
import Kadena.Sender.Types (SenderServiceChannel)
import Kadena.Log.Types (LogServiceChannel)
import Kadena.Evidence.Spec (EvidenceChannel)
import Kadena.Types.Execution (ExecutionChannel)
import Kadena.Types.History (HistoryChannel)
import Kadena.Types.PreProc (ProcessRequestChannel)
import Kadena.Private.Types (PrivateChannel)
import Kadena.Types.Message (InboundCMDChannel,OutboundGeneralChannel)
import Kadena.Types.Event (ConsensusEventChannel)

data Dispatch = Dispatch
  { _dispInboundAER      :: InboundAERChannel
  , _dispInboundCMD      :: InboundCMDChannel
  , _dispInboundRVorRVR  :: InboundRVorRVRChannel
  , _dispInboundGeneral  :: InboundGeneralChannel
  , _dispOutboundGeneral :: OutboundGeneralChannel
  , _dispConsensusEvent   :: ConsensusEventChannel
  , _dispSenderService   :: SenderServiceChannel
  , _dispLogService   :: LogServiceChannel
  , _dispEvidence   :: EvidenceChannel
  , _dispExecService :: ExecutionChannel
  , _dispHistoryChannel :: HistoryChannel
  , _dispProcessRequestChannel :: ProcessRequestChannel
  , _dispPrivateChannel :: PrivateChannel
  } deriving (Typeable)

initDispatch :: IO Dispatch
initDispatch = Dispatch
  <$> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms
  <*> initComms

makeLenses ''Dispatch
