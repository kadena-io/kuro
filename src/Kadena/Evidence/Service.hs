{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Evidence.Service
  ( runEvidenceService
  , initEvidenceEnv
  , module X
  ) where

import Control.Concurrent (MVar, newEmptyMVar, takeMVar, swapMVar, tryPutMVar, putMVar)
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

import Kadena.Types.Dispatch (Dispatch)
import Kadena.Types.Event (ResetLeaderNoFollowersTimeout(..))
import Kadena.Evidence.Spec as X
-- TODO: re-integrate EKG when Evidence Service is finished and hspec tests are written
-- import Kadena.Types.Metric
import qualified Kadena.Types.Dispatch as Dispatch
import qualified Kadena.Log.Types as Log

initEvidenceEnv :: Dispatch
                -> (String -> IO ())
                -> IORef Config
                -> MVar PublishedEvidenceState
                -> MVar ResetLeaderNoFollowersTimeout
                -> (Metric -> IO ())
                -> EvidenceEnv
initEvidenceEnv dispatch debugFn' mConfig' mPubStateTo' mResetLeaderNoFollowers' publishMetric' = EvidenceEnv
  { _logService = dispatch ^. Dispatch.logService
  , _evidence = dispatch ^. Dispatch.evidence
  , _mResetLeaderNoFollowers = mResetLeaderNoFollowers'
  , _mConfig = mConfig'
  , _mPubStateTo = mPubStateTo'
  , _debugFn = debugFn'
  , _publishMetric = publishMetric'
  }

rebuildState :: Maybe EvidenceState -> EvidenceProcEnv (EvidenceState)
rebuildState es = do
  conf' <- view mConfig >>= liftIO . readIORef
  otherNodes' <- return $ _otherNodes conf'
  maxElectionTimeout' <- return $ snd $ _electionTimeoutRange conf'
  mv <- queryLogs $ Set.singleton Log.GetCommitIndex
  commitIndex' <- return $ Log.hasQueryResult Log.CommitIndex mv
  newEs <- return $! initEvidenceState otherNodes' commitIndex' maxElectionTimeout'
  case es of
    Just es' -> do
      res <- return $ es'
        { _esQuorumSize = _esQuorumSize newEs
        , _esMaxElectionTimeout = maxElectionTimeout'
        }
      return res
    Nothing -> do
      return $! newEs

publishEvidence :: EvidenceState -> EvidenceProcEnv ()
publishEvidence es = do
  esPub <- view mPubStateTo
  liftIO $ void $ swapMVar esPub $ PublishedEvidenceState (es ^. esConvincedNodes) (es ^. esNodeStates)
--  debug $ "Published Evidence" ++ show (es ^. esNodeStates)

runEvidenceProcessor :: EvidenceState -> EvidenceProcEnv EvidenceState
runEvidenceProcessor es = do
  newEv <- view evidence >>= liftIO . readComm
  -- every time we process evidence, we want to tick the 'alert consensus that they aren't talking to a wall' variable' to False
  es' <- return $! es {_esResetLeaderNoFollowers = False}
  case newEv of
    VerifiedAER aers -> do
      (res, newEs) <- return $! if Set.null $ _esCacheMissAers es'
                                then runState (processEvidence aers) es'
                                else let es'' = es' { _esCacheMissAers = Set.empty }
                                         aers' = aers ++ (Set.toList $ _esCacheMissAers es')
                                     in runState (processEvidence aers') es''
      publishEvidence newEs
      when (newEs ^. esResetLeaderNoFollowers) tellKadenaToResetLeaderNoFollowersTimeout
      case res of
        SteadyState ci -> do
          debug $ "CommitIndex still: " ++ show ci
          if (not $ Set.null $ newEs ^. esCacheMissAers)
          then processCacheMisses newEs >>= runEvidenceProcessor
          else runEvidenceProcessor newEs
        NeedMoreEvidence i -> do
          if (not $ Set.null $ newEs ^. esCacheMissAers)
          then processCacheMisses newEs >>= runEvidenceProcessor
          else do
            debug $ "evidence is still required (" ++ (show i) ++ " of " ++ show (1 + _esQuorumSize newEs) ++ ")"
            runEvidenceProcessor newEs
        NewCommitIndex ci -> do
          updateLogs $ Log.ULCommitIdx $ Log.UpdateCommitIndex ci
          debug $ "new CommitIndex: " ++ (show ci)
          if (not $ Set.null $ newEs ^. esCacheMissAers)
          then processCacheMisses newEs >>= runEvidenceProcessor
          else runEvidenceProcessor newEs
    Heart tock -> do
      liftIO (pprintBeat tock) >>= debug
      runEvidenceProcessor $ garbageCollectCache es
    Bounce -> do
      debug "restart command received!"
      return es
    ClearConvincedNodes -> do
      -- Consensus has signaled that an election has or is taking place
      debug "clearing convinced nodes"
      runEvidenceProcessor $ es {_esConvincedNodes = Set.empty}
    CacheNewHash{..} -> do
      debug $ "new hash to cache received: " ++ show _cLogIndex
      runEvidenceProcessor $ es
        { _esEvidenceCache = Map.insert _cLogIndex _cHash (_esEvidenceCache es)
        , _esMaxCachedIndex = if _cLogIndex > (_esMaxCachedIndex es) then _cLogIndex else (_esMaxCachedIndex es)
        }

runEvidenceService :: EvidenceEnv -> IO ()
runEvidenceService ev = do
  startingEs <- runReaderT (rebuildState Nothing) ev
  putMVar (ev ^. mPubStateTo) $! PublishedEvidenceState (startingEs ^. esConvincedNodes) (startingEs ^. esNodeStates)
  runReaderT (foreverRunProcessor startingEs) ev

foreverRunProcessor :: EvidenceState -> EvidenceProcEnv ()
foreverRunProcessor es = do
  debug "launching!"
  runEvidenceProcessor es >>= rebuildState . Just >>= foreverRunProcessor

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
  liftIO $ debugFn' $ "[Service|Evidence]: " ++ s

garbageCollectCache :: EvidenceState -> EvidenceState
garbageCollectCache es =
  let dropCnt = (Map.size $ _esEvidenceCache es) - 1000
  in if dropCnt > 0
     then es {_esEvidenceCache = Map.fromAscList $ drop dropCnt $ Map.toAscList $ _esEvidenceCache es}
     else es

checkPartialEvidence :: Int -> Map LogIndex Int -> Either Int LogIndex
checkPartialEvidence evidenceNeeded partialEvidence = go (Map.toDescList partialEvidence) evidenceNeeded
  where
    go [] eStillNeeded = Left eStillNeeded
    go ((li, cnt):pes) en
      | en - cnt <= 0 = Right li
      | otherwise     = go pes (en - cnt)
{-# INLINE checkPartialEvidence #-}

checkForNewCommitIndex :: EvidenceProcessor CommitCheckResult
checkForNewCommitIndex = do
  partialEvidence <- use esPartialEvidence
  commitIndex' <- use esCommitIndex
  if Map.null partialEvidence
  -- Only populated when we see aerLogIndex > commitIndex. If it's empty, then nothings happening
  then return $ SteadyState commitIndex'
  else do
    quorumSize' <- use esQuorumSize
    case checkPartialEvidence quorumSize' partialEvidence of
      Left i -> return $ NeedMoreEvidence i
      Right ci | ci > commitIndex' -> do
        esEvidenceCache' <- use esEvidenceCache
        newHash <- case Map.lookup ci esEvidenceCache' of
          Nothing -> do
             es <- get
             error $ "deep invariant error: checkForNewCommitIndex found a new commit index "
                   ++ show ci ++ " but the hash was not in the Evidence Cache\n### STATE DUMP ###\n"
                   ++ show es
          Just h -> return h
        esHashAtCommitIndex .= newHash
        esCommitIndex .= ci
        -- though the code in `processResult Successful` should be enough to keep everything in sync
        -- we're going to make doubly sure that we don't double count
        esPartialEvidence %= Map.filterWithKey (\k _ -> k > ci)
        return $ NewCommitIndex ci
               | otherwise         -> return $ SteadyState commitIndex'
--        es <- get
--        error $ "Deep invariant error: Calculated a new commit index lower than our current one: "
--              ++ show ci ++ " <= " ++ show commitIndex'
--              ++ "\n### STATE DUMP ###\n" ++ show es

processCacheMisses :: EvidenceState -> EvidenceProcEnv (EvidenceState)
processCacheMisses es = do
  (aerCacheMisses, futureAers) <- return $ Set.partition (\a -> _aerIndex a <= _esMaxCachedIndex es) (es ^. esCacheMissAers)
  if Set.null aerCacheMisses
  then do
    debug $ "all " ++ show (Set.size futureAers) ++ " cache miss(s) were for future log indicies"
    return es
  else do
    debug $ "processing " ++ show (Set.size aerCacheMisses) ++ " Cache Misses"
    c <- view logService
    mv <- liftIO $ newEmptyMVar
    liftIO $ writeComm c $ Log.NeedCacheEvidence (Set.map _aerIndex aerCacheMisses) mv
    newCacheEv <- liftIO $ takeMVar mv
    updatedEs <- return $ es
      { _esEvidenceCache = Map.union newCacheEv $ _esEvidenceCache es
      , _esCacheMissAers = futureAers}
    (res, newEs) <- return $! runState (processEvidence $ Set.toList aerCacheMisses) updatedEs
    if (newEs == updatedEs)
    -- the cached evidence may not have changed anything, doubtful but could happen
    then return newEs
    else do
      publishEvidence newEs
      when (newEs ^. esResetLeaderNoFollowers) tellKadenaToResetLeaderNoFollowersTimeout
      case res of
        SteadyState _ ->
          return newEs
        NeedMoreEvidence i -> do
          debug $ "even after processing cache misses, evidence still required (" ++ (show i) ++ " of " ++ show (1 + _esQuorumSize newEs) ++ ")"
          return newEs
        NewCommitIndex ci -> do
          updateLogs $ Log.ULCommitIdx $ Log.UpdateCommitIndex ci
          debug $ "after processing cache misses, new CommitIndex: " ++ (show ci)
          return newEs

processEvidence :: [AppendEntriesResponse] -> EvidenceProcessor CommitCheckResult
processEvidence aers = do
  es <- get
  mapM_ processResult (checkEvidence es <$> aers)
  checkForNewCommitIndex
{-# INLINE processEvidence #-}

-- | The semantics for this are that the MVar is initialized empty, when Evidence needs to signal consensus it puts
-- the MVar and when consensus needs to check it (every heartbeat) it does so. Now, Evidence will be tryPut-ing all
-- the freaking time (possibly clusterSize/aerBatchSize per second) but Consensus only needs to check once per second.
tellKadenaToResetLeaderNoFollowersTimeout :: EvidenceProcEnv ()
tellKadenaToResetLeaderNoFollowersTimeout = do
  m <- view mResetLeaderNoFollowers
  liftIO $ void $ tryPutMVar m $! ResetLeaderNoFollowersTimeout

-- ### METRICS STUFF ###
-- TODO: re-integrate this after Evidence thread is finished and hspec tests are written
--logMetric :: Metric -> EvidenceProcEnv ()
--logMetric metric = view publishMetric >>= \f -> liftIO $ f metric
--
--updateLNextIndex :: LogIndex
--                 -> (Map.Map NodeId LogIndex -> Map.Map NodeId LogIndex)
--                 -> Consensus ()
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
--              -> Consensus ()
--setLNextIndex myCommitIndex = updateLNextIndex myCommitIndex . const
