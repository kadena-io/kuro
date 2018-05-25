{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Command
  ( encodeCommand, decodeCommand, decodeCommandEither
  , {- decodeCommandIO, -} decodeCommandEitherIO
  , verifyCommand, verifyCommandIfNotPending
  , prepPreprocCommand
  , runPreproc, runPreprocPure
  , finishPreProc
  , toRequestKey
  , initCmdLat, populateCmdLat
  , mkLatResults
  ) where

import Control.Exception
import Control.Lens
import Control.Monad
import Control.Concurrent

import qualified Data.Serialize as S

import Data.Thyme.Clock
import Data.Thyme.Time.Core ()

import Kadena.Execution.ConfigChange
import Kadena.Types.Base
import Kadena.Types.Command
import Kadena.Types.Message.Signed

import qualified Pact.Types.Command as Pact

initCmdLat :: Maybe ReceivedAt -> Maybe CmdLatencyMetrics
initCmdLat Nothing = Nothing
initCmdLat (Just (ReceivedAt startTime)) = Just $ CmdLatencyMetrics
  { _lmFirstSeen = startTime
  , _lmHitTurbine = Nothing
  , _lmHitConsensus = Nothing
  , _lmFinConsensus = Nothing
  , _lmAerConsensus = Nothing
  , _lmLogConsensus = Nothing
  , _lmHitPreProc = Nothing
  , _lmFinPreProc = Nothing
  , _lmHitExecution = Nothing
  , _lmFinExecution = Nothing
  }

populateCmdLat ::
  CmdLatASetter a
  -> UTCTime
  -> Maybe CmdLatencyMetrics
  -> Maybe CmdLatencyMetrics
populateCmdLat l t = fmap (over l (\_ -> Just t))
{-# INLINE populateCmdLat #-}

runPreprocPure :: RunPreProc -> FinishedPreProc
runPreprocPure RunSCCPreProc{..} =
  let !res = Pact.verifyCommand _rpSccRaw
  in res `seq` FinishedPreProcSCC res _rpSccMVar
runPreprocPure RunCCCPreProc{..} =
  let !res = processClusterChange _rpCccRaw
  in res `seq` FinishedPreProcCCC res _rpCccMVar
{-# INLINE runPreprocPure #-}

finishPreProc :: UTCTime -> UTCTime -> FinishedPreProc -> IO ()
finishPreProc startTime endTime FinishedPreProcSCC{..} = do
  succPut <- tryPutMVar _fppSccMVar $! PendingResult _fppSccRes (Just startTime) (Just endTime)
  unless succPut $ putStrLn $ "Preprocessor encountered a duplicate: " ++ show _fppSccRes
finishPreProc startTime endTime FinishedPreProcCCC{..} = do
  succPut <- tryPutMVar _fppCccMVar $! PendingResult _fppCccRes (Just startTime) (Just endTime)
  unless succPut $ putStrLn $ "Preprocessor encountered a duplicate: " ++ show _fppCccRes
{-# INLINE finishPreProc #-}

runPreproc :: UTCTime -> RunPreProc -> IO ()
runPreproc hitPreProc RunSCCPreProc{..} = do
  res <- return $! Pact.verifyCommand _rpSccRaw
  finishedPreProc <- getCurrentTime
  succPut <- tryPutMVar _rpSccMVar $! PendingResult res (Just hitPreProc) (Just finishedPreProc)
  unless succPut $ putStrLn $ "Preprocessor encountered a duplicate: " ++ show _rpSccRaw
runPreproc hitPreProc RunCCCPreProc{..} = do
  res <- return $! processClusterChange _rpCccRaw
  finishedPreProc <- getCurrentTime
  succPut <- tryPutMVar _rpCccMVar $! PendingResult res (Just hitPreProc) (Just finishedPreProc)
  unless succPut $ putStrLn $ "Preprocessor encountered a duplicate: " ++ show _rpCccRaw
{-# INLINE runPreproc #-}

encodeCommand :: Command -> CMDWire
encodeCommand SmartContractCommand{..} = SCCWire $! S.encode _sccCmd
encodeCommand ConsensusChangeCommand{..} = CCCWire $! S.encode _cccCmd
encodeCommand PrivateCommand{..} = PCWire $! S.encode _pcCmd
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
decodeCommand (CCCWire !b) =
  let
    !cmd = case S.decode b of
      Left err -> throw $ DeserializationError $ err ++ "\n### for ###\n" ++ show b
      Right v -> v
    !res = ConsensusChangeCommand cmd Unprocessed
  in res `seq` res
decodeCommand (PCWire !b) =
  let
    !cmd = case S.decode b of
      Left err -> throw $ DeserializationError $ err ++ "\n### for ###\n" ++ show b
      Right v -> v
    !res = PrivateCommand cmd
  in res `seq` res
{-# INLINE decodeCommand #-}

decodeCommandEither :: CMDWire -> Either String Command
decodeCommandEither (SCCWire !b) = case S.decode b of
  Left !err -> Left $! err ++ "\n### for ###\n" ++ show b
  Right !cmd -> Right $! (SmartContractCommand cmd Unprocessed)
decodeCommandEither (CCCWire !b) = case S.decode b of
  Left !err -> Left $! err ++ "\n### for ###\n" ++ show b
  Right !cmd -> Right $! (ConsensusChangeCommand cmd Unprocessed)
decodeCommandEither (PCWire !b) = case S.decode b of
  Left !err -> Left $! err ++ "\n### for ###\n" ++ show b
  Right !cmd -> Right $! (PrivateCommand cmd)
{-# INLINE decodeCommandEither #-}

decodeCommandEitherIO :: CMDWire -> IO (Either String (Command, Maybe RunPreProc))
decodeCommandEitherIO cmd = case decodeCommandEither cmd of
  Left err -> return $ Left $ err ++ "\n### for ###\n" ++ show cmd
  Right v -> case v of
    r@SmartContractCommand{..} -> do
      mv <- newEmptyMVar
      let rpp = RunSCCPreProc _sccCmd mv
      return $ Right $! (r { _sccPreProc = Pending mv }, Just rpp)
    r@ConsensusChangeCommand{..} -> do
      mv <- newEmptyMVar
      let rpp = RunCCCPreProc _cccCmd mv
      return $! Right $! (r { _cccPreProc = Pending mv }, Just rpp)
    r@PrivateCommand{} -> return $! Right (r,Nothing)

prepPreprocCommand :: Command -> IO (Command, Maybe RunPreProc)
prepPreprocCommand cmd@SmartContractCommand{..} = do
  case _sccPreProc of
    Unprocessed -> do
      mv <- newEmptyMVar
      return $ (cmd { _sccPreProc = Pending mv}, Just $ RunSCCPreProc _sccCmd mv)
    err -> error $ "Invariant Error: cmd has already been preped: " ++ show err ++ "\n### for ###\n" ++ show _sccCmd
prepPreprocCommand cmd@ConsensusChangeCommand{..} = do
  case _cccPreProc of
    Unprocessed -> do
      mv <- newEmptyMVar
      return $ (cmd { _cccPreProc = Pending mv}, Just $ RunCCCPreProc _cccCmd mv)
    err -> error $ "Invariant Error: cmd has already been preped: " ++ show err ++ "\n### for ###\n" ++ show _cccCmd
prepPreprocCommand c@PrivateCommand{} = return $! (c,Nothing)

verifyCommandIfNotPending :: Command -> Command
verifyCommandIfNotPending cmd@SmartContractCommand{..} =
  let res = case _sccPreProc of
              Unprocessed -> verifyCommand cmd
              Pending{} -> cmd
              Result{} -> cmd
  in res `seq` res
verifyCommandIfNotPending cmd@ConsensusChangeCommand{..} =
  let res = case _cccPreProc of
              Unprocessed -> verifyCommand cmd
              Pending{} -> cmd
              Result{} -> cmd
  in res `seq` res
verifyCommandIfNotPending cmd@PrivateCommand{} = cmd
{-# INLINE verifyCommandIfNotPending #-}

verifyCommand :: Command -> Command
verifyCommand cmd@SmartContractCommand{..} =
  let !res = Result $! Pact.verifyCommand _sccCmd
  in res `seq` cmd { _sccPreProc = res }
verifyCommand cmd@ConsensusChangeCommand{..} =
  let !res = Result $! processClusterChange _cccCmd
  in res `seq` cmd { _cccPreProc = res }
verifyCommand cmd@PrivateCommand{} = cmd
{-# INLINE verifyCommand #-}

toRequestKey :: Command -> RequestKey
toRequestKey = RequestKey . getCmdBodyHash
{-# INLINE toRequestKey #-}

mkLatResults :: CmdLatencyMetrics -> CmdResultLatencyMetrics
mkLatResults CmdLatencyMetrics{..} = CmdResultLatencyMetrics
  { _rlmFirstSeen = _lmFirstSeen
  , _rlmHitTurbine = interval _lmFirstSeen <$> _lmHitTurbine
  , _rlmHitConsensus = interval _lmFirstSeen <$> _lmHitConsensus
  , _rlmFinConsensus = interval _lmFirstSeen <$> _lmFinConsensus
  , _rlmAerConsensus = interval _lmFirstSeen <$> _lmAerConsensus
  , _rlmLogConsensus = interval _lmFirstSeen <$> _lmLogConsensus
  , _rlmHitPreProc = interval _lmFirstSeen <$> _lmHitPreProc
  , _rlmFinPreProc = interval _lmFirstSeen <$> _lmFinPreProc
  , _rlmHitExecution = interval _lmFirstSeen <$> _lmHitExecution
  , _rlmFinExecution = interval _lmFirstSeen <$> _lmFinExecution
  }
