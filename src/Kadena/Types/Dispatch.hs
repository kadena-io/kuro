{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Dispatch
  ( Dispatch(..), initDispatch
  , inboundAER
  , inboundCMD
  , inboundRVorRVR
  , inboundGeneral
  , outboundGeneral
  , cfgChangeService
  , consensusEvent
  , senderService
  , logService
  , evidence
  , execService
  , historyChannel
  , processRequestChannel
  , privateChannel
  ) where

import Control.Lens

import Data.Typeable

import Kadena.Types.Comms
import Kadena.Sender.Types (SenderServiceChannel)
import Kadena.Log.Types (LogServiceChannel)
import Kadena.Evidence.Spec (EvidenceChannel)
import Kadena.Execution.Types (ExecutionChannel)
import Kadena.History.Types (HistoryChannel)
import Kadena.PreProc.Types (ProcessRequestChannel)
import Kadena.Private.Types (PrivateChannel)
import Kadena.Types.Message (InboundCMDChannel,OutboundGeneralChannel)
import Kadena.Types.Event (ConsensusEventChannel)
import Kadena.ConfigChange.Types(ConfigChangeChannel)

data Dispatch = Dispatch
  { _inboundAER      :: InboundAERChannel
  , _inboundCMD      :: InboundCMDChannel
  , _inboundRVorRVR  :: InboundRVorRVRChannel
  , _inboundGeneral  :: InboundGeneralChannel
  , _outboundGeneral :: OutboundGeneralChannel
  , _cfgChangeService :: ConfigChangeChannel
  , _consensusEvent   :: ConsensusEventChannel
  , _senderService   :: SenderServiceChannel
  , _logService   :: LogServiceChannel
  , _evidence   :: EvidenceChannel
  , _execService :: ExecutionChannel
  , _historyChannel :: HistoryChannel
  , _processRequestChannel :: ProcessRequestChannel
  , _privateChannel :: PrivateChannel
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
  <*> initComms

makeLenses ''Dispatch
