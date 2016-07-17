{-# LANGUAGE TemplateHaskell #-}

module Juno.Types.Dispatch
  ( Dispatch(..), initDispatch
  , inboundAER
  , inboundCMD
  , inboundRVorRVR
  , inboundGeneral
  , outboundGeneral
  , outboundAerRvRvr
  , internalEvent
  , senderService
  , logService
  , evidence
  ) where

import Control.Lens

import Data.Typeable

import Juno.Types.Comms
import Juno.Types.Service.Sender (SenderServiceChannel)
import Juno.Types.Service.Log (LogServiceChannel)
import Juno.Types.Service.Evidence (EvidenceChannel)

data Dispatch = Dispatch
  { _inboundAER      :: InboundAERChannel
  , _inboundCMD      :: InboundCMDChannel
  , _inboundRVorRVR  :: InboundRVorRVRChannel
  , _inboundGeneral  :: InboundGeneralChannel
  , _outboundGeneral :: OutboundGeneralChannel
  , _outboundAerRvRvr :: OutboundAerRvRvrChannel
  , _internalEvent   :: InternalEventChannel
  , _senderService   :: SenderServiceChannel
  , _logService   :: LogServiceChannel
  , _evidence   :: EvidenceChannel
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

makeLenses ''Dispatch