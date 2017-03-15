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
  , PendingResult(..)
  , getCmdBodyHash
  , SCCPreProcResult
  , CMDWire(..)
  , toRequestKey
  , CommandResult(..), scrResult, scrHash, cmdrLogIndex, cmdrLatMetrics
  , CmdLatencyMetrics(..), lmFirstSeen, lmHitTurbine, lmHitPreProc
  , lmFinPreProc, lmHitCommit, lmFinCommit, lmHitConsensus, lmFinConsensus
  , initCmdLat, populateCmdLat
  , CmdLatASetter
  , CmdResultLatencyMetrics(..)
  , rlmFirstSeen, rlmHitTurbine, rlmHitConsensus, rlmFinConsensus
  , rlmHitPreProc, rlmFinPreProc, rlmHitCommit, rlmFinCommit
  , mkLatResults
  ) where

import Control.Exception
import Control.Lens
import Control.Monad
import Control.Concurrent

import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import Data.ByteString (ByteString)

import Data.Thyme.Clock
import Data.Thyme.Time.Core ()
import Data.Aeson
import GHC.Generics
import GHC.Int (Int64)

import Kadena.Types.Base
import Kadena.Types.Message.Signed

import qualified Pact.Types.Command as Pact
import qualified Pact.Types.RPC as Pact
import Pact.Types.Util

data CmdLatencyMetrics = CmdLatencyMetrics
  { _lmFirstSeen :: !UTCTime
  , _lmHitTurbine :: !(Maybe UTCTime)
  , _lmHitConsensus :: !(Maybe UTCTime)
  , _lmFinConsensus :: !(Maybe UTCTime)
  , _lmHitPreProc :: !(Maybe UTCTime)
  , _lmFinPreProc :: !(Maybe UTCTime)
  , _lmHitCommit :: !(Maybe UTCTime)
  , _lmFinCommit :: !(Maybe UTCTime)
  } deriving (Show, Eq, Ord, Generic)
makeLenses ''CmdLatencyMetrics

instance ToJSON CmdLatencyMetrics where
  toJSON = lensyToJSON 3
instance FromJSON CmdLatencyMetrics where
  parseJSON = lensyParseJSON 3

initCmdLat :: Maybe ReceivedAt -> Maybe CmdLatencyMetrics
initCmdLat Nothing = Nothing
initCmdLat (Just (ReceivedAt startTime)) = Just $ CmdLatencyMetrics
  { _lmFirstSeen = startTime
  , _lmHitTurbine = Nothing
  , _lmHitConsensus = Nothing
  , _lmFinConsensus = Nothing
  , _lmHitPreProc = Nothing
  , _lmFinPreProc = Nothing
  , _lmHitCommit = Nothing
  , _lmFinCommit = Nothing
  }

type CmdLatASetter a = ASetter CmdLatencyMetrics CmdLatencyMetrics a (Maybe UTCTime)

populateCmdLat ::
  CmdLatASetter a
  -> UTCTime
  -> Maybe CmdLatencyMetrics
  -> Maybe CmdLatencyMetrics
populateCmdLat l t = fmap (over l (\_ -> Just t))
{-# INLINE populateCmdLat #-}

data PendingResult a = PendingResult
  { _prResult :: !a
  , _prStartedPreProc :: !(Maybe UTCTime)
  , _prFinishedPreProc :: !(Maybe UTCTime)
  }

data Preprocessed a =
  Unprocessed |
  Pending {pending :: !(MVar (PendingResult a))} |
  Result {result :: a}
  deriving (Eq, Generic)
instance (Show a) => Show (Preprocessed a) where
  show Unprocessed = "Unprocessed"
  show Pending{} = "Pending {unPending = <MVar>}"
  show (Result a) = "Result {unResult = " ++ show a ++ "}"

type SCCPreProcResult = PendingResult (Pact.ProcessedCommand Pact.PactRPC)

data RunPreProc =
  RunSCCPreProc
    { _rpSccRaw :: !(Pact.Command ByteString)
    , _rpSccMVar :: !(MVar SCCPreProcResult)}

runPreproc :: UTCTime -> RunPreProc -> IO ()
runPreproc hitPreProc RunSCCPreProc{..} = do
  res <- return $! Pact.verifyCommand _rpSccRaw
  finishedPreProc <- getCurrentTime
  succPut <- tryPutMVar _rpSccMVar $! PendingResult res (Just hitPreProc) (Just finishedPreProc)
  unless succPut $ putStrLn $ "Preprocessor encountered a duplicate: " ++ show _rpSccRaw

data Command = SmartContractCommand
  { _sccCmd :: !(Pact.Command ByteString)
  , _sccPreProc :: !(Preprocessed (Pact.ProcessedCommand Pact.PactRPC))
  } deriving (Show, Eq, Generic)
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

data CmdResultLatencyMetrics = CmdResultLatencyMetrics
  { _rlmFirstSeen :: !UTCTime
  , _rlmHitTurbine :: !(Maybe Int64)
  , _rlmHitConsensus :: !(Maybe Int64)
  , _rlmFinConsensus :: !(Maybe Int64)
  , _rlmHitPreProc :: !(Maybe Int64)
  , _rlmFinPreProc :: !(Maybe Int64)
  , _rlmHitCommit :: !(Maybe Int64)
  , _rlmFinCommit :: !(Maybe Int64)
  } deriving (Show, Eq, Ord, Generic)
makeLenses ''CmdResultLatencyMetrics

instance ToJSON CmdResultLatencyMetrics where
  toJSON = lensyToJSON 4
instance FromJSON CmdResultLatencyMetrics where
  parseJSON = lensyParseJSON 4

mkLatResults :: CmdLatencyMetrics -> CmdResultLatencyMetrics
mkLatResults CmdLatencyMetrics{..} = CmdResultLatencyMetrics
  { _rlmFirstSeen = _lmFirstSeen
  , _rlmHitTurbine = interval _lmFirstSeen <$> _lmHitTurbine
  , _rlmHitConsensus = interval _lmFirstSeen <$> _lmHitConsensus
  , _rlmFinConsensus = interval _lmFirstSeen <$> _lmFinConsensus
  , _rlmHitPreProc = interval _lmFirstSeen <$> _lmHitPreProc
  , _rlmFinPreProc = interval _lmFirstSeen <$> _lmFinPreProc
  , _rlmHitCommit = interval _lmFirstSeen <$> _lmHitCommit
  , _rlmFinCommit = interval _lmFirstSeen <$> _lmFinCommit
  }

data CommandResult = SmartContractResult
  { _scrHash :: !Hash
  , _scrResult :: !Pact.CommandResult
  , _cmdrLogIndex :: !LogIndex
  , _cmdrLatMetrics :: !(Maybe CmdResultLatencyMetrics)
  }
  deriving (Show, Eq, Generic)
makeLenses ''CommandResult
