{-# LANGUAGE RecordWildCards #-}

module Kadena.Evidence.Service
  ( runEvidenceService
  , initEvidenceEnv
  -- exported for testing
  , checkPartialEvidence'
  ) where

import Control.Concurrent (MVar, newEmptyMVar, takeMVar, swapMVar, tryPutMVar, putMVar)
import Control.Lens hiding (Index)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.RWS.Lazy
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Thyme.Clock
import Safe

import Kadena.Config.ClusterMembership
import Kadena.ConfigChange as CC
import Kadena.Util.Util (linkAsyncTrack)
import Kadena.Types.Dispatch (Dispatch)
import Kadena.Event (pprintBeat)
import Kadena.Types.Event (ResetLeaderNoFollowersTimeout(..))
import Kadena.Evidence.Spec as X
import Kadena.Types.Metric (Metric)
import Kadena.Config.TMVar
import Kadena.Config.Types
import Kadena.Evidence.Types
import Kadena.Types.Log as Log
import Kadena.Types.Message
import Kadena.Types.Base
import Kadena.Types.Comms

-- TODO: re-integrate EKG when Evidence Service is finished and hspec tests are written
-- import Kadena.Types.Metric
import qualified Kadena.Types.Dispatch as Dispatch
import qualified Kadena.Log.Types as Log

initEvidenceEnv :: Dispatch
                -> (String -> IO ())
                -> GlobalConfigTMVar
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

initializeState :: EvidenceEnv -> IO EvidenceState
initializeState ev = do
  Config{..} <- readCurrentConfig $ view mConfig ev
  maxElectionTimeout' <- return $ snd $ _electionTimeoutRange
  mv <- queryLogs ev $ Set.singleton Log.GetCommitIndex
  commitIndex' <- return $ Log.hasQueryResult Log.CommitIndex mv
  return $! initEvidenceState _clusterMembers commitIndex' maxElectionTimeout'

-- | This handles initialization and config updates
handleConfUpdate :: EvidenceService EvidenceState ()
handleConfUpdate = do
  es@EvidenceState{..} <- get
  Config{..} <- view mConfig >>= liftIO . readCurrentConfig
  -- if there are no transitional config-change nodes AND there are no changes to the current nodes configuration
  if not (hasTransitionalNodes _clusterMembers)
     && otherNodes _esClusterMembers == otherNodes _clusterMembers
     && (snd _electionTimeoutRange) == _esMaxElectionTimeout
  then do
    debug "Config update received but no action required"
    return ()
  else do
    maxElectionTimeout' <- return $ snd $ _electionTimeoutRange
    -- df === nodes to add/remove when adopting the env's config, which is now different from what is
    --        stored in the state
    let df = CC.diffNodes (otherNodes _esClusterMembers) (otherNodes _clusterMembers)
    -- update the map of nodes -> (LogIndex, UTCTime) accordingly
    let updatedMap = CC.updateNodeMap df _esNodeStates (const (startIndex, minBound))
    -- df' === nodes to add/remove when moving to the transitional config-change nodes
    let df' = CC.diffNodes (otherNodes _esClusterMembers) (transitionalNodes _clusterMembers)
    -- update (again) the map of nodes -> (LogIndex, UTCTime) accordingly
    let updatedMap' = CC.updateNodeMap df' updatedMap (const (startIndex, minBound))
    put $ es
      { _esClusterMembers = _clusterMembers
      , _esQuorumSize = getEvidenceQuorumSize $ countOthers _clusterMembers
      , _esChangeToQuorumSize = getEvidenceQuorumSize $ countTransitional _clusterMembers
      , _esNodeStates = updatedMap'
      , _esConvincedNodes = Set.difference _esConvincedNodes $ nodesToRemove df
      , _esMismatchNodes = Set.difference _esMismatchNodes $nodesToRemove df
      , _esMaxElectionTimeout = maxElectionTimeout'
      }
    publishEvidence
    debug "Config update received, update implemented"
    return ()

publishEvidence :: EvidenceService EvidenceState ()
publishEvidence = do
  es <- get
  esPub <- view mPubStateTo
  liftIO $ void $ swapMVar esPub $ PublishedEvidenceState (es ^. esConvincedNodes) (es ^. esNodeStates)

runEvidenceProcessor :: EvidenceService EvidenceState ()
runEvidenceProcessor = do
  env <- ask
  es <- get
  newEv <- view evidence >>= liftIO . readComm
  case newEv of
    VerifiedAER aers -> do
      -- every time we process evidence, we want to tick the 'alert consensus that they aren't talking to a wall'...
      let es' = es {_esResetLeaderNoFollowers = False}
      -- ... variable to False
      (res, newEs, _) <- liftIO $! if Set.null $ _esCacheMissAers es'
                                    then runRWST (processEvidence aers) env es'
                                    else let es'' = es' { _esCacheMissAers = Set.empty }
                                             aers' = aers ++ (Set.toList $ _esCacheMissAers es')
                                         in runRWST (processEvidence aers') env es''
      put newEs
      publishEvidence
      when (newEs ^. esResetLeaderNoFollowers) tellKadenaToResetLeaderNoFollowersTimeout
      processCommitCkResult res
      runEvidenceProcessor
    Heart tock -> do
      liftIO (pprintBeat tock) >>= debug
      put $ garbageCollectCache es
      runEvidenceProcessor
    Bounce -> do
      put $ garbageCollectCache es
      -- MLN: eventually remove this.  Its a placeholder if any central activity on config change needs to happen
      -- liftIO $ CC.runWithNewConfig
      runEvidenceProcessor
    ClearConvincedNodes -> do
      debug "clearing convinced nodes"
      put $ es {_esConvincedNodes = Set.empty}
      runEvidenceProcessor
    CacheNewHash{..} -> do
      debug $ "new hash to cache received: " ++ show _cLogIndex
      put $ es
        { _esEvidenceCache = Map.insert _cLogIndex _cHash (_esEvidenceCache es)
        , _esMaxCachedIndex = if _cLogIndex > (_esMaxCachedIndex es) then _cLogIndex else (_esMaxCachedIndex es)
        }
      runEvidenceProcessor

processCommitCkResult :: CommitCheckResult -> EvidenceService EvidenceState ()
processCommitCkResult (SteadyState ci) = do
  debug $ "CommitIndex still: " ++ show ci
  updateCache
processCommitCkResult (StrangeResultInProcessor ci) = do
  debug $ "CommitIndex still: " ++ show ci
  debug $ "checkForNewCommitIndex is in a funny state likely because the cluster is under load, we'll see if it resolves itself: " ++ show ci
processCommitCkResult (NeedMoreEvidence i i') = do
  newEs <- get
  case Set.null $ newEs ^. esCacheMissAers of
    True | i /= 0 ->
      debug $ "evidence is still required (" ++ (show i) ++ " of " ++ show (1 + _esQuorumSize newEs) ++ ")"
    True | i' /= 0 ->
      debug $ "evidence is still required for the incoming confiuration change consensus list ("
              ++ (show i') ++ " of " ++ show (1 + _esChangeToQuorumSize newEs) ++ ")"
    _ -> return ()
  updateCache

processCommitCkResult(NewCommitIndex ci) = do
  now' <- liftIO $ getCurrentTime
  updateLogs $ Log.ULCommitIdx $ Log.UpdateCommitIndex ci now'
  debug $ "new CommitIndex: " ++ (show ci)
  updateCache

updateCache :: EvidenceService EvidenceState ()
updateCache = do
  newEs <- get
  unless (Set.null $ newEs ^. esCacheMissAers)
    processCacheMisses

runEvidenceService :: EvidenceEnv -> IO ()
runEvidenceService ev = do
  startingEs <- initializeState ev
  putMVar (ev ^. mPubStateTo) $! PublishedEvidenceState (startingEs ^. esConvincedNodes) (startingEs ^. esNodeStates)
  let cu = ConfigUpdater (ev ^. debugFn) "Service|Evidence|Config" (const $ writeComm (ev ^. evidence) $ Bounce)
  linkAsyncTrack "EvidenceConfUpdater" $ CC.runConfigUpdater cu (ev ^. mConfig)
  _ <- runRWST (debug "Launch!" >> foreverRunProcessor) ev startingEs
  return ()

foreverRunProcessor :: (EvidenceService EvidenceState) ()
foreverRunProcessor = do
  runEvidenceProcessor
  handleConfUpdate
  foreverRunProcessor

queryLogs :: EvidenceEnv -> Set Log.AtomicQuery -> IO (Map Log.AtomicQuery Log.QueryResult)
queryLogs env aq = do
  let c = view logService env
  mv <- liftIO $ newEmptyMVar
  writeComm c $ Log.Query aq mv
  takeMVar mv

updateLogs :: Log.UpdateLogs -> EvidenceService EvidenceState ()
updateLogs q = do
  logService' <- view logService
  liftIO $ writeComm logService' $ Log.Update q

debug :: String -> EvidenceService EvidenceState ()
debug s = do
  debugFn' <- view debugFn
  liftIO $ debugFn' $ "[Service|Evidence]: " ++ s

garbageCollectCache :: EvidenceState -> EvidenceState
garbageCollectCache es =
  let dropCnt = (Map.size $ _esEvidenceCache es) - 1000
  in if dropCnt > 0
     then es {_esEvidenceCache = Map.fromAscList $ drop dropCnt $ Map.toAscList $ _esEvidenceCache es}
     else es

checkPartialEvidence :: Int -> Int -> Map LogIndex (Set NodeId) -> EvidenceService EvidenceState (Either [Int] LogIndex)
checkPartialEvidence evidenceNeeded changeToEvNeeded partialEvidence = do
  es <- get
  let nodes = otherNodes (_esClusterMembers es)
  let chgToNodes = transitionalNodes(_esClusterMembers es)
  return $ checkPartialEvidence' nodes chgToNodes evidenceNeeded changeToEvNeeded partialEvidence
{-# INLINE checkPartialEvidence #-}

checkPartialEvidence' :: (Set NodeId) -> (Set NodeId) -> Int -> Int -> Map LogIndex (Set NodeId) -> Either [Int] LogIndex
checkPartialEvidence' nodes chgToNodes evidenceNeeded changeToEvNeeded partialEvidence =
  -- fold the (Map LogIndex (Set NodeId)) into [Map LogIndex Int]
  -- where the Ints represent the count of votes at a particular index
  -- the first list item is built from log entries whose nodeId is part of the current config
  -- the second list item is built from log entries whose nodeId is part of the transitional config
  let emptyMap = Map.empty :: Map LogIndex Int
      (nodeMap, changeToNodeMap) =
        Map.foldrWithKey f (emptyMap, emptyMap) partialEvidence where
          f :: LogIndex -> (Set NodeId)-> (Map LogIndex Int, Map LogIndex Int) -> (Map LogIndex Int, Map LogIndex Int)
          f k x (r1, r2) =
            let inNodeSet = Set.filter (\nId -> nId `elem` nodes ) x
                inChangeToNodeSet = Set.filter (\nId -> nId `elem` chgToNodes) x
            in (Map.insert k (length inNodeSet) r1, Map.insert k (length inChangeToNodeSet) r2)
  in if null changeToNodeMap
      then go (Map.toDescList nodeMap) evidenceNeeded
      else case ( go (Map.toDescList nodeMap) evidenceNeeded
                , go (Map.toDescList changeToNodeMap) changeToEvNeeded) of
              (Left l1, Left l2)   -> Left (l1 ++ l2) -- missing regular and transitional evidence
              (Left l, Right _)    -> Left (l ++ [0])   -- missing only regular evidence
              (Right _, Left l)    -> Left (0 : l)   -- missing only transitional evidence
              (Right r1, Right _) ->  Right r1 -- Ok, only use the main consensus list for the log index
  where
    go :: [(LogIndex, Int)] -> Int -> Either [Int] LogIndex
    go [] eStillNeeded = Left [eStillNeeded]
    go ((li, cnt) : pes) en
      | en - cnt <= 0 = Right li
      | otherwise     = go pes (en - cnt)
{-# INLINE checkPartialEvidence' #-}

checkForNewCommitIndex :: EvidenceService EvidenceState CommitCheckResult
checkForNewCommitIndex = do
  partialEvidence <- use esPartialEvidence
  commitIndex' <- use esCommitIndex
  if Map.null partialEvidence
    -- Only populated when we see aerLogIndex > commitIndex. If it's empty, then nothings happening
    then return $ SteadyState commitIndex'
    else do
      qSize <- use esQuorumSize
      changeToQSize <- use esChangeToQuorumSize
      checkResult <- checkPartialEvidence qSize changeToQSize partialEvidence
      case checkResult of
        Left ns -> return $ NeedMoreEvidence
          { _ccrEvRequired = headDef 0 ns
          , _ccrChangeToEvRequired = head $ tailDef [0] ns }
        Right ci
          | ci > commitIndex' -> do
              esEvidenceCache' <- use esEvidenceCache
              case Map.lookup ci esEvidenceCache' of
                -- TODO: this tripped a bug in prod (64 node cluster, par-batch 200k 2k/s 500ms) in June... not sure what happened
                --  es <- get
                --  error $ "deep invariant error: checkForNewCommitIndex found a new commit index "
                --          ++ show ci ++ " but the hash was not in the Evidence Cache\n### STATE DUMP ###\n"
                --          ++ show es
                Nothing -> return $ StrangeResultInProcessor ci
                Just newHash -> do
                  esHashAtCommitIndex .= newHash
                  esCommitIndex .= ci
                  -- though the code in `processResult Successful` should be enough to keep everything in sync
                  -- we're going to make doubly sure that we don't double count
                  esPartialEvidence %= Map.filterWithKey (\k _ -> k > ci)
                  return $ NewCommitIndex ci
          | otherwise -> return $ SteadyState commitIndex'

processCacheMisses :: EvidenceService EvidenceState ()
processCacheMisses = do
  env <- ask
  es <- get
  (aerCacheMisses, futureAers) <- return $ Set.partition (\a -> _aerIndex a <= _esMaxCachedIndex es) (es ^. esCacheMissAers)
  if Set.null aerCacheMisses
  then do
    debug $ "all " ++ show (Set.size futureAers) ++ " cache miss(s) were for future log indicies"
    return ()
  else do
    debug $ "processing " ++ show (Set.size aerCacheMisses) ++ " Cache Misses"
    c <- view logService
    mv <- liftIO $ newEmptyMVar
    liftIO $ writeComm c $ Log.NeedCacheEvidence (Set.map _aerIndex aerCacheMisses) mv
    newCacheEv <- liftIO $ takeMVar mv
    updatedEs <- return $ es
      { _esEvidenceCache = Map.union newCacheEv $ _esEvidenceCache es
      , _esCacheMissAers = futureAers}
    (res, newEs, _) <- liftIO $! runRWST (processEvidence $ Set.toList aerCacheMisses) env updatedEs
    put newEs
    if (newEs == updatedEs)
    -- the cached evidence may not have changed anything, doubtful but could happen
    then return ()
    else do
      publishEvidence
      when (newEs ^. esResetLeaderNoFollowers) tellKadenaToResetLeaderNoFollowersTimeout
      case res of
        SteadyState _ -> return ()
        NeedMoreEvidence i i' ->
          case (i, i') of
            (x, _) | x /= 0 ->
              debug $ "even after processing cache misses, evidence still required (" ++ (show i) ++ " of " ++ show (1 + _esQuorumSize newEs) ++ ")"
            (_, y) | y /= 0 ->
              debug $ "even after processing cache misses, evidence still required for the incoming confiuration change consensus list ("
                      ++ (show i') ++ " of " ++ show (1 + _esChangeToQuorumSize newEs) ++ ")"
            _ -> return ()
        StrangeResultInProcessor ci -> do
          debug $ "checkForNewCommitIndex is in a funny state likely because the cluster is under load, we'll see if it resolves itself: " ++ show ci
          return ()
        NewCommitIndex ci -> do
          now' <- liftIO $ getCurrentTime
          updateLogs $ Log.ULCommitIdx $ Log.UpdateCommitIndex ci now'
          debug $ "after processing cache misses, new CommitIndex: " ++ (show ci)
          return ()

processEvidence :: [AppendEntriesResponse] -> EvidenceService EvidenceState CommitCheckResult
processEvidence aers = do
  es <- get
  mapM_ processResult (checkEvidence es <$> aers)
  checkForNewCommitIndex
{-# INLINE processEvidence #-}

-- | The semantics for this are that the MVar is initialized empty, when Evidence needs to signal consensus it puts
-- the MVar and when consensus needs to check it (every heartbeat) it does so. Now, Evidence will be tryPut-ing all
-- the freaking time (possibly clusterSize/aerBatchSize per second) but Consensus only needs to check once per second.
--tellKadenaToResetLeaderNoFollowersTimeout :: EvidenceProcEnv ()
tellKadenaToResetLeaderNoFollowersTimeout :: EvidenceService EvidenceState ()
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
