{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Command
  ( Command(..), sccCmd, sccPreProc
  , encodeCommand, decodeCommand, decodeCommandEither
  , decodeCommandIO, decodeCommandEitherIO
  , verifyCommand, verifyCommandIfNotPending
  , prepPreprocCommand
  , Preprocessed(..), RunPreProc(..), runPreproc
  , getCmdBodyHash
  , SCCPreProcResult
  , CMDWire(..)
  , toRequestKey
  , CommandResult(..), scrResult, scrHash, cmdrLogIndex, cmdrLatency
  ) where

import Control.Exception
import Control.Lens
import Control.Monad
import Control.Concurrent

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

data Preprocessed a =
  Unprocessed |
  Pending {pending :: !(MVar a)} |
  Result {result :: a}
  deriving (Eq, Generic)
instance (Show a) => Show (Preprocessed a) where
  show Unprocessed = "Unprocessed"
  show Pending{} = "Pending {unPending = <MVar>}"
  show (Result a) = "Result {unResult = " ++ show a ++ "}"

type SCCPreProcResult = Pact.ProcessedCommand Pact.PactRPC

data RunPreProc =
  RunSCCPreProc
    { _rpSccRaw :: !(Pact.Command ByteString)
    , _rpSccMVar :: !(MVar SCCPreProcResult)}

runPreproc :: RunPreProc -> IO ()
runPreproc RunSCCPreProc{..} = do
  succPut <- tryPutMVar _rpSccMVar $! Pact.verifyCommand _rpSccRaw
  unless succPut $ putStrLn $ "Preprocessor encountered a duplicate: " ++ show _rpSccRaw

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

decodeCommandIO :: CMDWire -> IO (Command, RunPreProc)
decodeCommandIO cmd = do
  mv <- newEmptyMVar
  return $ case decodeCommand cmd of
    r@SmartContractCommand{..} ->
      let rpp = RunSCCPreProc _sccCmd mv
      in (r { _sccPreProc = Pending mv }, rpp)

decodeCommandEitherIO :: CMDWire -> IO (Either String (Command, RunPreProc))
decodeCommandEitherIO cmd = do
  case decodeCommandEither cmd of
    Left err -> return $ Left $ err ++ "\n### for ###\n" ++ show cmd
    Right v -> do
      mv <- newEmptyMVar
      case v of
        r@SmartContractCommand{..} ->
          let rpp = RunSCCPreProc _sccCmd mv
          in return $ Right (r { _sccPreProc = Pending mv }, rpp)

prepPreprocCommand :: Command -> IO (Command, RunPreProc)
prepPreprocCommand cmd@SmartContractCommand{..} = do
  case _sccPreProc of
    Unprocessed -> do
      mv <- newEmptyMVar
      return $ (cmd { _sccPreProc = Pending mv}, RunSCCPreProc _sccCmd mv)
    err -> error $ "Invariant Error: cmd has already been preped: " ++ show err ++ "\n### for ###\n" ++ show _sccCmd

verifyCommandIfNotPending :: Command -> Command
verifyCommandIfNotPending cmd@SmartContractCommand{..} =
  let res = case _sccPreProc of
              Unprocessed -> verifyCommand cmd
              Pending{} -> cmd
              Result{} -> cmd
  in res `seq` res
{-# INLINE verifyCommandIfNotPending #-}

verifyCommand :: Command -> Command
verifyCommand cmd@SmartContractCommand{..} =
  let !res = Result $! Pact.verifyCommand _sccCmd
  in res `seq` cmd { _sccPreProc = res }
{-# INLINE verifyCommand #-}

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
