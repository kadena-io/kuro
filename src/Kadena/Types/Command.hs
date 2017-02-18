{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Command
  ( Command(..), sccCmd, sccPreProc
  , encodeCommand, decodeCommand
  , encodeCommand', decodeCommand'
  , getCmdBodyHash
  , CMDWire(..)
  , toRequestKey
  , CommandResult(..), scrResult, cmdrLatency
  ) where

import Control.Exception
import Control.Parallel
import Control.Lens

import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import Data.ByteString (ByteString)

import Data.Thyme.Time.Core ()
import GHC.Generics
import GHC.Int (Int64)

import Kadena.Types.Base
import Kadena.Types.Message.Signed

import qualified Pact.Types.Command as Pact
import qualified Pact.Types.RPC as Pact

-- TODO: upgrade pact to have this
deriving instance (Ord a) => Ord (Pact.Command a)

data Command = SmartContractCommand
  { _sccCmd :: !(Pact.Command ByteString)
  -- it's important to keep this lazy! we'll be sparking it at decode time
  , _sccPreProc :: Pact.ProcessedCommand Pact.PactRPC
  }
  deriving (Show, Eq, Generic)
makeLenses ''Command

instance Ord Command where
  compare a b = compare (_sccCmd a) (_sccCmd b)

data CMDWire = SCCWire !ByteString deriving (Show, Eq, Generic)

encodeCommand :: Command -> CMDWire
encodeCommand SmartContractCommand{..} = SCCWire $ S.encode _sccCmd
{-# INLINE encodeCommand #-}

encodeCommand' :: Command -> CMDWire
encodeCommand' SmartContractCommand{..} = SCCWire $! S.encode _sccCmd
{-# INLINE encodeCommand' #-}

-- | Decodes CMDWire to Command but sparks the crypto portion using `Control.Parallel.par`.
-- The behavior of this is effectively, if the RTS can perform the crypto in parallel at some point do it
-- but if we need the value before that, run the computation sequentially. This tactic is experimental as of 2/2017.
--   Decode the  Throws `DeserializationError`
decodeCommand :: CMDWire -> Command
decodeCommand (SCCWire !b) =
  let
    !cmd = case S.decode b of
      Left err -> throw $ DeserializationError $ err ++ "\n### for ###\n" ++ show b
      Right v -> v
    pp = Pact.verifyCommand cmd
  in pp `par` (SmartContractCommand cmd pp)
{-# INLINE decodeCommand #-}

-- | Decode the  Throws `DeserializationError`
decodeCommand' :: CMDWire -> Command
decodeCommand' (SCCWire !b) =
  let
    !cmd = case S.decode b of
      Left !err -> throw $ DeserializationError $ err ++ "\n### for ###\n" ++ show b
      Right !v -> v
    !pp = Pact.verifyCommand cmd
  in pp `seq` (SmartContractCommand cmd pp)
{-# INLINE decodeCommand' #-}



instance Serialize CMDWire

getCmdBodyHash :: Command -> Hash
getCmdBodyHash SmartContractCommand{ _sccCmd = Pact.PublicCommand{..}} = _cmdHash

toRequestKey :: Command -> RequestKey
toRequestKey SmartContractCommand{..} = RequestKey (Pact._cmdHash _sccCmd)
{-# INLINE toRequestKey #-}

data CommandResult = SmartContractResult
  { _scrResult :: !Pact.CommandResult
  , _cmdrLatency :: !Int64
  }
  deriving (Show, Eq, Generic)
makeLenses ''CommandResult
