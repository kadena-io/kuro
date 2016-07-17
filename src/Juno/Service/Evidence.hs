{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Service.Evidence
  ( runEvidenceService
  , initEvidenceEnv
  , module X
  -- for benchmarks
  , _runEvidenceProcessTest
  ) where

import Control.Concurrent (MVar, readMVar, newEmptyMVar, takeMVar, swapMVar, tryPutMVar, putMVar)
import Control.Lens hiding (Index)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Reader
import Control.Monad.Trans.State.Strict

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.IORef

import qualified Data.ByteString.Char8 as BSC
import Data.Yaml (encode)

import Debug.Trace

import Juno.Types.Dispatch (Dispatch)
import Juno.Types.Event (ResetLeaderNoFollowersTimeout(..))
import Juno.Types.Service.Evidence as X
-- TODO: re-integrate EKG when Evidence Service is finished and hspec tests are written
-- import Juno.Types.Metric
import qualified Juno.Types.Dispatch as Dispatch
import qualified Juno.Types.Service.Log as Log

initEvidenceEnv :: Dispatch
                -> (String -> IO ())
                -> IORef Config
                -> MVar EvidenceState
                -> MVar EvidenceCache
                -> MVar ResetLeaderNoFollowersTimeout
                -> EvidenceEnv
initEvidenceEnv dispatch debugFn' mConfig' mPubStateTo' mEvCache' mResetLeaderNoFollowers' = EvidenceEnv
  { _logService = dispatch ^. Dispatch.logService
  , _evidence = dispatch ^. Dispatch.evidence
  , _mResetLeaderNoFollowers = mResetLeaderNoFollowers'
  , _mConfig = mConfig'
  , _mPubStateTo = mPubStateTo'
  , _mEvCache = mEvCache'
  , _debugFn = debugFn'
  }

rebuildState :: Maybe EvidenceState -> EvidenceProcEnv (EvidenceState)
rebuildState es = do
  conf' <- view mConfig >>= liftIO . readIORef
  otherNodes' <- return $ _otherNodes conf'
  mv <- queryLogs $ Set.singleton Log.GetCommitIndex
  commitIndex' <- return $ Log.hasQueryResult Log.CommitIndex mv
  newEs <- return $! initEvidenceState otherNodes' commitIndex'
  case es of
    Just es' -> do
      res <- return $ es'
        { _esQuorumSize = _esQuorumSize newEs
        }
      debug $ "rebuilt state to: " ++ (BSC.unpack $ encode res)
      return res
    Nothing -> do
      debug $ "state was nothing, built: " ++ (BSC.unpack $ encode newEs)
      return $! newEs

runEvidenceProcessor :: EvidenceState -> EvidenceProcEnv (EvidenceState)
runEvidenceProcessor es = do
  newEv <- view evidence >>= liftIO . readComm
  -- every time we process evidence, we want to tick the 'alert consensus that they aren't talking to a wall' variable' to False
  es' <- return $! es {_esResetLeaderNoFollowers = False}
  case newEv of
    VerifiedAER aers -> do
      esPub <- view mPubStateTo
      ec <- view mEvCache >>= liftIO . readMVar
      (res, newEs) <- return $! runState (processEvidence aers ec) es'
      liftIO $ void $ swapMVar esPub newEs
      when (newEs ^. esResetLeaderNoFollowers) tellJunoToResetLeaderNoFollowersTimeout
      case res of
        Left i -> do
          debug $ "Evidence still required " ++ (show i) ++ " of " ++ show (1 + _esQuorumSize newEs)
          runEvidenceProcessor newEs
        Right li -> do
          updateLogs $ Log.ULCommitIdx $ Log.UpdateCommitIndex li
          debug $ "CommitIndex = " ++ (show li)
          runEvidenceProcessor newEs
    Tick tock -> do
      liftIO (pprintTock tock "runEvidenceProcessor") >>= debug
      runEvidenceProcessor es
    Bounce -> return es
    ClearConvincedNodes -> do
      -- Consensus has signaled that an election has or is taking place
      debug "Clearing Convinced Nodes"
      runEvidenceProcessor $ es {_esConvincedNodes = Set.empty}

runEvidenceService :: EvidenceEnv -> IO ()
runEvidenceService ev = do
  startingEs <- runReaderT (rebuildState Nothing) ev
  putMVar (ev ^. mPubStateTo) startingEs
  runReaderT (foreverRunProcessor startingEs) ev

foreverRunProcessor :: EvidenceState -> EvidenceProcEnv ()
foreverRunProcessor es = runEvidenceProcessor es >>= rebuildState . Just >>= foreverRunProcessor

queryLogs :: Set Log.AtomicQuery -> EvidenceProcEnv (Map Log.AtomicQuery Log.QueryResult)
queryLogs aq = do
  c <- view logService
  mv <- liftIO $ newEmptyMVar
  liftIO $ writeComm c $ Log.Query aq mv
  liftIO $ takeMVar mv

updateLogs :: Log.UpdateLogs -> EvidenceProcEnv ()
updateLogs q = do
  logService' <- view logService
  liftIO $ writeComm logService' $ Log.Update q

debug :: String -> EvidenceProcEnv ()
debug s = do
  debugFn' <- view debugFn
  liftIO $ debugFn' $ "[EV_SERVICE]: " ++ s

checkForNewCommitIndex :: Int -> Map LogIndex Int -> Either Int LogIndex
checkForNewCommitIndex evidenceNeeded partialEvidence = go (Map.toDescList partialEvidence) evidenceNeeded
  where
    go [] eStillNeeded = Left eStillNeeded
    go ((li, cnt):pes) en
      | en - cnt <= 0 = Right li
      | otherwise     = go pes (en - cnt)
{-# INLINE checkForNewCommitIndex #-}

processEvidence :: [AppendEntriesResponse] -> EvidenceCache -> EvidenceProcessor (Either Int LogIndex)
processEvidence aers ec = do
  es <- get
  mapM_ processResult (traceShowId . checkEvidence ec es <$> aers)
  res <- checkForNewCommitIndex (_esQuorumSize es) <$> use esPartialEvidence
  case res of
    Left i -> return $ Left i
    Right li -> do
      esCommitIndex .= li
      -- though the code in `processResult Successful` should be enough to keep everything in sync
      -- we're going to make doubly sure that we don't double count
      esPartialEvidence %= Map.filterWithKey (\k _ -> k > li)
      return $ Right li
{-# INLINE processEvidence #-}

-- | The semantics for this are that the MVar is initialized empty, when Evidence needs to signal consensus it puts
-- the MVar and when consensus needs to check it (every heartbeat) it does so. Now, Evidence will be tryPut-ing all
-- the freaking time (possibly clusterSize/aerBatchSize per second) but Consensus only needs to check once per second.
tellJunoToResetLeaderNoFollowersTimeout :: EvidenceProcEnv ()
tellJunoToResetLeaderNoFollowersTimeout = do
  m <- view mResetLeaderNoFollowers
  liftIO $ void $ tryPutMVar m ResetLeaderNoFollowersTimeout

-- ### METRICS STUFF ###
-- TODO: re-integrate this after Evidence thread is finished and hspec tests are written
--logMetric :: Metric -> EvidenceProcEnv ()
--logMetric metric = view publishMetric >>= \f -> liftIO $ f metric
--
--updateLNextIndex :: LogIndex
--                 -> (Map.Map NodeId LogIndex -> Map.Map NodeId LogIndex)
--                 -> Raft ()
--updateLNextIndex myCommitIndex f = do
--  lNextIndex %= f
--  lni <- use lNextIndex
--  logMetric $ MetricAvailableSize $ availSize lni myCommitIndex
--
--  where
--    -- | The number of nodes at most one behind the commit index
--    availSize lni ci = let oneBehind = pred ci
--                       in succ $ Map.size $ Map.filter (>= oneBehind) lni
--
--setLNextIndex :: LogIndex
--              -> Map.Map NodeId LogIndex
--              -> Raft ()
--setLNextIndex myCommitIndex = updateLNextIndex myCommitIndex . const

-- For Testing

_runEvidenceProcessTest
  :: (EvidenceState, EvidenceCache, [AppendEntriesResponse])
  -> (Either Int LogIndex, EvidenceState)
_runEvidenceProcessTest (es, ec, aers) = runState (processEvidence aers ec) es

_checkEvidence :: (EvidenceState, EvidenceCache, AppendEntriesResponse) -> Result
_checkEvidence (es, ec, aer) = checkEvidence ec es aer
