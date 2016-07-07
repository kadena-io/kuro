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
  ) where

import Control.Lens

import Data.Typeable

import Juno.Types.Comms
import Juno.Types.Sender (SenderServiceChannel)

data Dispatch = Dispatch
  { _inboundAER      :: InboundAERChannel
  , _inboundCMD      :: InboundCMDChannel
  , _inboundRVorRVR  :: InboundRVorRVRChannel
  , _inboundGeneral  :: InboundGeneralChannel
  , _outboundGeneral :: OutboundGeneralChannel
  , _outboundAerRvRvr :: OutboundAerRvRvrChannel
  , _internalEvent   :: InternalEventChannel
  , _senderService   :: SenderServiceChannel
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

makeLenses ''Dispatch
