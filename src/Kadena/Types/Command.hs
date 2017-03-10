{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Command
  ( Command(..), sccCmd, sccPreProc
  , encodeCommand, decodeCommand, decodeCommandEither
  , Preprocessed(..), preprocessCmd
  , getCmdBodyHash
  , CMDWire(..)
  , toRequestKey
  , CommandResult(..), scrResult, scrHash, cmdrLogIndex, cmdrLatency
  ) where

import Control.Exception
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

data Preprocessed a = Unprocessed | Processed { _ppProcessed :: !a}
  deriving (Show, Eq, Ord, Generic)

data Command = SmartContractCommand
  { _sccCmd :: !(Pact.Command ByteString)
  , _sccPreProc :: !(Preprocessed (Pact.ProcessedCommand Pact.PactRPC))
  }
  deriving (Show, Eq, Generic)
makeLenses ''Command

instance Ord Command where
  compare a b = compare (_sccCmd a) (_sccCmd b)

data CMDWire = SCCWire !ByteString deriving (Show, Eq, Generic)
instance Serialize CMDWire

encodeCommand :: Command -> CMDWire
encodeCommand SmartContractCommand{..} = SCCWire $! S.encode _sccCmd
{-# INLINE encodeCommand #-}

-- | Decode that throws `DeserializationError`
decodeCommand :: CMDWire -> Command
decodeCommand (SCCWire !b) =
  let
    !cmd = case S.decode b of
      Left err -> throw $ DeserializationError $ err ++ "\n### for ###\n" ++ show b
      Right v -> v
    !res = SmartContractCommand cmd Unprocessed
  in res `seq` res
{-# INLINE decodeCommand #-}

decodeCommandEither :: CMDWire -> Either String Command
decodeCommandEither (SCCWire !b) = case S.decode b of
  Left !err -> Left $! err ++ "\n### for ###\n" ++ show b
  Right !cmd -> Right $! (SmartContractCommand cmd Unprocessed)
{-# INLINE decodeCommandEither #-}

preprocessCmd :: Command -> Command
preprocessCmd SmartContractCommand{..} =
  let !pp = Pact.verifyCommand _sccCmd
  in pp `seq` (SmartContractCommand _sccCmd $! Processed pp)
{-# INLINE preprocessCmd #-}

getCmdBodyHash :: Command -> Hash
getCmdBodyHash SmartContractCommand{ _sccCmd = Pact.PublicCommand{..}} = _cmdHash

toRequestKey :: Command -> RequestKey
toRequestKey SmartContractCommand{..} = RequestKey (Pact._cmdHash _sccCmd)
{-# INLINE toRequestKey #-}

data CommandResult = SmartContractResult
  { _scrHash :: !Hash
  , _scrResult :: !Pact.CommandResult
  , _cmdrLogIndex :: !LogIndex
  , _cmdrLatency :: !Int64
  }
  deriving (Show, Eq, Generic)
makeLenses ''CommandResult
