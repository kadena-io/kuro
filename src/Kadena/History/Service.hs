{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}

module Kadena.History.Service
  ( initHistoryEnv
  , runHistoryService
  , module X
  ) where

import Control.Lens hiding (Index, (|>))
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict
import Control.Concurrent.MVar

import Data.Semigroup ((<>))
import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.Thyme.Clock
#if WITH_KILL_SWITCH
import Data.Thyme.Clock.POSIX
#endif
import Data.Maybe (fromJust,isJust,isNothing)
import System.FilePath

import Kadena.Util.Util
import Kadena.Types.Base
import Kadena.Types.Config
import Kadena.Config.TMVar
import Kadena.Types.History as X
import qualified Kadena.History.Persistence as DB
import Kadena.Types.Dispatch (Dispatch)
import qualified Kadena.Types.Dispatch as D
import Kadena.Event (pprintBeat)

initHistoryEnv
  :: Dispatch
  -> (String -> IO ())
  -> IO UTCTime
  -> Config
  -> HistoryEnv
initHistoryEnv dispatch' debugPrint' getTimestamp' rconf = HistoryEnv
  { _historyChannel = dispatch' ^. D.historyChannel
  , _debugPrint = debugPrint'
  , _getTimestamp = getTimestamp'
  , _dbPath = if rconf ^. enablePersistence
              then Just $ (rconf ^. logDir) </> (show $ _alias $ rconf ^. (nodeId)) ++ "-logResult.sqlite"
              else Nothing
  }

runHistoryService :: HistoryEnv -> Maybe HistoryState -> IO ()
runHistoryService env mState = catchAndRethrow "historyService" $ do
  let dbg = env ^. debugPrint
  let oChan = env ^. historyChannel
  initHistoryState <- case mState of
    Nothing -> do
      pers <- setupPersistence dbg (env ^. dbPath)
      return $! HistoryState { _registeredListeners = HashMap.empty, _persistence = pers }
    Just mState' -> return mState'
  dbg "[Service|Histoy] Launch!"
  (_,bouncedState,_) <- runRWST (handle oChan) env initHistoryState
  runHistoryService env (Just bouncedState)

debug :: String -> HistoryService ()
debug s = do
  dbg <- view debugPrint
  liftIO $! dbg $ "[Service|History] " ++ s

now :: HistoryService UTCTime
now = view getTimestamp >>= liftIO

setupPersistence :: (String -> IO ()) -> Maybe FilePath -> IO PersistenceSystem
setupPersistence dbg Nothing = do
  dbg $ "[Service|History] Persistence Disabled"
  return $ InMemory HashMap.empty
setupPersistence dbg (Just dbPath') = do
  dbg $ "[Service|History] Persistence Enabled: " ++ dbPath'
  conn <- DB.createDB dbPath'
  return $ OnDisk { incompleteRequestKeys = HashSet.empty
                  , dbConn = conn }

#if WITH_KILL_SWITCH
-- | time based kill switch, deliberately obtuse
_k'' :: HistoryService ()
_k'' = do
  t <- liftIO $ getPOSIXTime
  te :: POSIXTime <- return $ read $ "1538352000s"
  when (t >= te) $ do
    error "Demo period complete. Please contact us for updated binaries."
#endif

handle :: HistoryChannel -> HistoryService ()
handle oChan = do
  q <- liftIO $ readComm oChan
  unless (q == Bounce) $ do
    case q of
      Heart t -> do
        liftIO (pprintBeat t) >>= debug
#if WITH_KILL_SWITCH
        _k''
#endif
      AddNew{..} ->  addNewKeys hNewKeys
      Update{..} -> updateExistingKeys hUpdateRks
      QueryForExistence{..} -> queryForExisting hQueryForExistence
      QueryForPriorApplication{..} -> queryForPriorApplication hQueryForPriorApplication
      QueryForResults{..} -> queryForResults hQueryForResults
      RegisterListener{..} -> registerNewListeners hNewListener
      PruneInFlightKeys{..} -> clearSomePendingRks hKeysToPrune
      -- I thought it cleaner to match on bounce above instead of opening up the potential to forget to loop
      Bounce -> error "Unreachable Path: you can't hit bounce twice"
    handle oChan

addNewKeys :: HashSet RequestKey -> HistoryService ()
addNewKeys srks = do
  pers <- use persistence
  start <- now
  case pers of
    InMemory m -> do
      persistence .= InMemory (HashMap.union m $ const Nothing <$> HashSet.toMap srks)
    OnDisk{..} -> do
      persistence .= OnDisk { incompleteRequestKeys = HashSet.union incompleteRequestKeys srks
                            , dbConn = dbConn }
  end <- now
  debug $ "Added " ++ show (HashSet.size srks) ++ " new keys (" ++ printInterval start end ++ ")"

updateExistingKeys :: HashMap RequestKey CommandResult -> HistoryService ()
updateExistingKeys updates = do
  alertListeners updates
  pers <- use persistence
  start <- now
  case pers of
    InMemory m -> do
      newInMem <- return $! InMemory $! foldr updateInMemKey m $ HashMap.toList updates
      persistence .= newInMem
    OnDisk{..} -> do
      liftIO $ DB.insertCompletedCommand dbConn $ HashMap.elems updates
      persistence .= OnDisk { incompleteRequestKeys = HashSet.filter (\k -> not $ HashMap.member k updates) incompleteRequestKeys
                            , dbConn = dbConn }
  end <- now
  debug $ "Updated " ++ show (HashMap.size updates) ++ " keys (" ++ printInterval start end ++ ")"

updateInMemKey :: (RequestKey, CommandResult) -> HashMap RequestKey (Maybe CommandResult) -> HashMap RequestKey (Maybe CommandResult)
updateInMemKey (k,v) m = HashMap.insert k (Just v) m

alertListeners :: HashMap RequestKey CommandResult -> HistoryService ()
alertListeners m = do
  start <- now
  listeners <- use registeredListeners
  triggered <- return $! HashMap.filterWithKey (\k _ -> HashMap.member k m) listeners
  unless (HashMap.null triggered) $ do
    res <- mapM (alertListener m) $ HashMap.toList triggered
    registeredListeners %= HashMap.filterWithKey (\k _ -> not $ HashMap.member k triggered)
    -- use registeredListeners >>= debug . ("Active Listeners: " ++) . show . HashMap.keysSet
    end <- now
    debug $ "Serviced " ++ show (sum res) ++ " alerts (" ++ printInterval start end ++ ")"

alertListener :: HashMap RequestKey CommandResult -> (RequestKey, [MVar ListenerResult]) -> HistoryService Int
alertListener res (k,mvs) = do
  commandRes <- return $! res HashMap.! k
  -- debug $ "Servicing Listener for: " ++ show k
  fails <- filter not <$> liftIO (mapM (`tryPutMVar` ListenerResult commandRes) mvs)
  unless (null fails) $ debug $ "Registered listener failure for " ++ show k ++ " (" ++ show (length fails) ++ " of " ++ show (length mvs) ++ " failed)"
  return $ length mvs

queryForExisting :: (HashSet RequestKey, MVar ExistenceResult) -> HistoryService ()
queryForExisting (srks, mRes) = do
  pers <- use persistence
  start <- now
  case pers of
    InMemory m -> do
      found <- return $! HashSet.intersection srks $ HashSet.fromMap $ const () <$> m
      liftIO $! putMVar mRes $ ExistenceResult found
    OnDisk{..} -> do
      foundInMem <- return $ HashSet.intersection srks incompleteRequestKeys
      if HashSet.size foundInMem == HashSet.size srks
      -- unlikely but worth a O(1) check
      then liftIO $! putMVar mRes $ ExistenceResult foundInMem
      else do
        foundOnDisk <- liftIO $ DB.queryForExisting dbConn $ HashSet.filter (\k -> not $ HashSet.member k foundInMem) srks
        liftIO $! putMVar mRes $ ExistenceResult $! HashSet.union foundInMem foundOnDisk
  end <- now
  debug $ "Queried existence of " ++ show (HashSet.size srks) ++ " entries taking " ++ show (interval start end) ++ "mics"

queryForPriorApplication :: (HashSet RequestKey, MVar ExistenceResult) -> HistoryService ()
queryForPriorApplication (srks, mRes) = do
  pers <- use persistence
  start <- now
  case pers of
    InMemory m -> do
      found <- return $! HashSet.fromMap $ const () <$> HashMap.filterWithKey (\k v -> HashSet.member k srks && isJust v) m
      liftIO $! putMVar mRes $ ExistenceResult found
    OnDisk{..} -> do
      found <- liftIO $ DB.queryForExisting dbConn srks
      liftIO $! putMVar mRes $ ExistenceResult found
  end <- now
  debug $ "Queried prior application of " ++ show (HashSet.size srks) ++ " entries taking " ++ show (interval start end) ++ "mics"

queryForResults :: (HashSet RequestKey, MVar PossiblyIncompleteResults) -> HistoryService ()
queryForResults (srks, mRes) = do
  pers <- use persistence
  start <- now
  case pers of
    InMemory m -> do
      found <- return $! HashMap.filterWithKey (checkForIndividualResultInMem srks) m
      liftIO $! putMVar mRes $ PossiblyIncompleteResults $ fmap fromJust found
      debug $ "Querying for " ++ show (HashSet.size srks) ++ " keys, found " ++ show (HashMap.size found)
    OnDisk{..} -> do
      completed <- return $! HashSet.filter (\k -> not $ HashSet.member k incompleteRequestKeys) srks
      if HashSet.null completed
      then liftIO $! putMVar mRes $ PossiblyIncompleteResults $ HashMap.empty
      else do
        found <- liftIO $ DB.selectCompletedCommands dbConn completed
        liftIO $! putMVar mRes $ PossiblyIncompleteResults $ found
        debug $ "Querying for " ++ show (HashSet.size srks) ++ " keys, found " ++ show (HashMap.size found)
  end <- now
  debug $ "Queried results of " ++ show (HashSet.size srks) ++ " entries (" ++ show (interval start end) ++ "mics)"

-- This is here to try to get GHC to check the fast part first
checkForIndividualResultInMem :: HashSet RequestKey -> RequestKey -> Maybe CommandResult -> Bool
checkForIndividualResultInMem _ _ Nothing = False
checkForIndividualResultInMem s k (Just _) = HashSet.member k s

registerNewListeners :: HashMap RequestKey (MVar ListenerResult) -> HistoryService ()
registerNewListeners newListeners' = do
  start <- now
  srks <- return $! HashSet.fromMap $ const () <$> newListeners'
  pers <- use persistence
  found <- case pers of
    InMemory m -> return $! fromJust <$> HashMap.filterWithKey (checkForIndividualResultInMem srks) m
    OnDisk{..} -> liftIO $! DB.selectCompletedCommands dbConn srks
  noNeedToListen <- return $! HashSet.intersection (HashSet.fromMap $ const () <$> found) srks
  readyToServiceListeners <- return $! HashMap.filterWithKey (\k _ -> HashSet.member k noNeedToListen) newListeners'
  realListeners <- return $! HashMap.filterWithKey (\k _ -> not $ HashSet.member k noNeedToListen) newListeners'
  unless (HashMap.null readyToServiceListeners) $ do
    mapM_ (\(k,v) -> alertListener found (k,[v])) $ HashMap.toList readyToServiceListeners
    end <- now
    debug $ "Immediately serviced " ++ show (HashSet.size noNeedToListen) ++ " listeners (" ++ show (interval start end) ++ "mics)"
  unless (HashMap.null realListeners) $ do
    registeredListeners %= HashMap.unionWith (<>) ((:[]) <$> realListeners)
    end <- now
    debug $ "Registered " ++ show (HashMap.size realListeners) ++ " listeners (" ++ show (interval start end) ++ "mics)"

clearSomePendingRks :: HashSet RequestKey -> HistoryService ()
clearSomePendingRks srks = do
  pers <- use persistence
  start <- now
  case pers of
    InMemory m -> do
      pruned <- return $! InMemory $! HashMap.filterWithKey (\k v -> isNothing v && HashSet.member k srks) m
      persistence .= pruned
    OnDisk{..} -> do
      persistence .= OnDisk { incompleteRequestKeys = HashSet.difference incompleteRequestKeys srks
                            , dbConn = dbConn }
  end <- now
  debug $ "Pruned " ++ show (HashSet.size srks) ++ " keys (" ++ show (interval start end) ++ "mics)"

_gcVolLogListeners :: HashSet RequestKey -> HistoryService ()
_gcVolLogListeners srks = do
  toGc <- HashMap.filterWithKey (\k _ -> HashSet.member k srks) <$> use registeredListeners
  mapM_ (_gcListener "Transaction was GCed! This generally occurs because disk I/O is failing") $ HashMap.toList toGc
  registeredListeners %= HashMap.filterWithKey (\k _ -> not $ HashSet.member k srks)

_gcListener :: String -> (RequestKey, [MVar ListenerResult]) -> HistoryService ()
_gcListener res (k,mvs) = do
  fails <- filter not <$> liftIO (mapM (`tryPutMVar` GCed res) mvs)
  unless (null fails) $ debug $ "Registered listener failure during GC for " ++ show k ++ " (" ++ show (length fails) ++ " of " ++ show (length mvs) ++ " failed)"
