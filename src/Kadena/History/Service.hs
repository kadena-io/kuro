{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

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
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Thyme.Clock
import Data.Maybe (fromJust)



import Kadena.History.Types as X
import qualified Kadena.History.Persistence as DB
import Kadena.Types.Dispatch (Dispatch)
import qualified Kadena.Types.Dispatch as D

initHistoryEnv
  :: Dispatch
  -> Maybe FilePath
  -> (String -> IO ())
  -> IO UTCTime
  -> HistoryEnv
initHistoryEnv dispatch' dbPath' debugPrint' getTimestamp' = HistoryEnv
  { _historyChannel = dispatch' ^. D.historyChannel
  , _debugPrint = debugPrint'
  , _getTimestamp = getTimestamp'
  , _dbPath = dbPath'
  }

runHistoryService :: HistoryEnv -> Maybe HistoryState -> IO ()
runHistoryService env mState = do
  let dbg = env ^. debugPrint
  let oChan = env ^. historyChannel
  initHistoryState <- case mState of
    Nothing -> do
      pers <- setupPersistence dbg (env ^. dbPath)
      return $! HistoryState { _registeredListeners = Map.empty, _persistence = pers }
    Just mState' -> do
      return mState'
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
  return $ InMemory Map.empty
setupPersistence dbg (Just dbPath') = do
  dbg $ "[Service|History] Persistence Enabled: " ++ (dbPath' ++ "-cmdr.sqlite")
  conn <- DB.createDB $ (dbPath' ++ "-cmdr.sqlite")
  return $ OnDisk { incompleteRequestKeys = Set.empty
                  , dbConn = conn }

handle :: HistoryChannel -> HistoryService ()
handle oChan = do
  q <- liftIO $ readComm oChan
  unless (q == Bounce) $ do
    case q of
      Tick t -> liftIO (pprintTock t) >>= debug
      AddNew{..} ->  addNewKeys hNewKeys
      Update{..} -> updateExistingKeys hUpdateRks
      QueryForExistence{..} -> queryForExisting hQueryForExistence
      QueryForResults{..} -> queryForResults hQueryForResults
      RegisterListener{..} -> registerNewListeners hNewListener
      -- I thought it cleaner to match on bounce above instead of opening up the potential to forget to loop
      Bounce -> error "Unreachable Path: you can't hit bounce twice"
    handle oChan

addNewKeys :: Set RequestKey -> HistoryService ()
addNewKeys srks = do
  pers <- use persistence
  start <- now
  case pers of
    InMemory m -> do
      persistence .= InMemory (Map.union m $ Map.fromSet (const Nothing) srks)
    OnDisk{..} -> do
      persistence .= OnDisk { incompleteRequestKeys = Set.union incompleteRequestKeys srks
                            , dbConn = dbConn }
  end <- now
  debug $ "Added " ++ show (Set.size srks) ++ " new keys taking " ++ show (interval start end) ++ "mics"

updateExistingKeys :: Map RequestKey AppliedCommand -> HistoryService ()
updateExistingKeys updates = do
  alertListeners updates
  pers <- use persistence
  start <- now
  case pers of
    InMemory m -> do
      newInMem <- return $! InMemory $! foldr updateInMemKey m $ Map.toList updates
      persistence .= newInMem
    OnDisk{..} -> do
      liftIO $ DB.insertCompletedCommand dbConn updates
      persistence .= OnDisk { incompleteRequestKeys = Set.filter (\k -> Map.notMember k updates) incompleteRequestKeys
                            , dbConn = dbConn }
  end <- now
  debug $ "Updated " ++ show (Map.size updates) ++ " keys taking " ++ show (interval start end)

updateInMemKey :: (RequestKey, AppliedCommand) -> Map RequestKey (Maybe AppliedCommand) -> Map RequestKey (Maybe AppliedCommand)
updateInMemKey (k,v) m = Map.insert k (Just v) m

alertListeners :: Map RequestKey AppliedCommand -> HistoryService ()
alertListeners m = do
  start <- now
  listeners <- use registeredListeners
  triggered <- return $! Set.intersection (Map.keysSet m) (Map.keysSet listeners)
  unless (Set.null triggered) $ do
    res <- mapM (alertListener m) $ Map.toList $ Map.filterWithKey (\k _ -> Set.member k triggered) listeners
    registeredListeners %= Map.filterWithKey (\k _ -> Set.notMember k triggered)
    -- use registeredListeners >>= debug . ("Active Listeners: " ++) . show . Map.keysSet
    end <- now
    debug $ "Serviced " ++ show (sum res) ++ " alerts taking " ++ show (interval start end) ++ "mics"

alertListener :: Map RequestKey AppliedCommand -> (RequestKey, [MVar ListenerResult]) -> HistoryService Int
alertListener res (k,mvs) = do
  commandRes <- return $! res Map.! k
  -- debug $ "Servicing Listener for: " ++ show k
  fails <- filter not <$> liftIO (mapM (`tryPutMVar` ListenerResult commandRes) mvs)
  unless (null fails) $ debug $ "Registered listener failure for " ++ show k ++ " (" ++ show (length fails) ++ " of " ++ show (length mvs) ++ " failed)"
  return $ length mvs

queryForExisting :: (Set RequestKey, MVar ExistenceResult) -> HistoryService ()
queryForExisting (srks, mRes) = do
  pers <- use persistence
  start <- now
  case pers of
    InMemory m -> do
      found <- return $! Set.intersection srks $ Map.keysSet m
      liftIO $! putMVar mRes $ ExistenceResult found
    OnDisk{..} -> do
      foundInMem <- return $ Set.intersection srks incompleteRequestKeys
      if Set.size foundInMem == Set.size srks
      -- unlikely but worth a O(1) check
      then liftIO $! putMVar mRes $ ExistenceResult foundInMem
      else do
        foundOnDisk <- liftIO $ DB.queryForExisting dbConn $ Set.filter (`Set.notMember` foundInMem) srks
        liftIO $! putMVar mRes $ ExistenceResult $! Set.union foundInMem foundOnDisk
  end <- now
  debug $ "Queried existence of " ++ show (Set.size srks) ++ " entries taking " ++ show (interval start end) ++ "mics"

queryForResults :: (Set RequestKey, MVar PossiblyIncompleteResults) -> HistoryService ()
queryForResults (srks, mRes) = do
  pers <- use persistence
  start <- now
  case pers of
    InMemory m -> do
      found <- return $! Map.filterWithKey (checkForIndividualResultInMem srks) m
      liftIO $! putMVar mRes $ PossiblyIncompleteResults $ fmap fromJust found
      debug $ "Querying for " ++ show (Set.size srks) ++ " keys, found " ++ show (Map.size found)
    OnDisk{..} -> do
      completed <- return $! Set.filter (`Set.notMember` incompleteRequestKeys) srks
      if Set.null completed
      then do
        liftIO $! putMVar mRes $ PossiblyIncompleteResults $ Map.empty
      else do
        found <- liftIO $ DB.selectCompletedCommands dbConn completed
        liftIO $! putMVar mRes $ PossiblyIncompleteResults $ found
  end <- now
  debug $ "Queried results of " ++ show (Set.size srks) ++ " entries taking " ++ show (interval start end) ++ "mics"

-- This is here to try to get GHC to check the fast part first
checkForIndividualResultInMem :: Set RequestKey -> RequestKey -> Maybe AppliedCommand -> Bool
checkForIndividualResultInMem _ _ Nothing = False
checkForIndividualResultInMem s k (Just _) = Set.member k s

registerNewListeners :: Map RequestKey (MVar ListenerResult) -> HistoryService ()
registerNewListeners newListeners' = do
  start <- now
  srks <- return $! Map.keysSet newListeners'
  pers <- use persistence
  found <- case pers of
    InMemory m -> do
      return $! fromJust <$> Map.filterWithKey (checkForIndividualResultInMem srks) m
    OnDisk{..} -> do
      liftIO $! DB.selectCompletedCommands dbConn srks
  noNeedToListen <- return $! Set.intersection (Map.keysSet found) srks
  readyToServiceListeners <- return $! Map.filterWithKey (\k _ -> Set.member k noNeedToListen) newListeners'
  realListeners <- return $! Map.filterWithKey (\k _ -> not $ Set.member k noNeedToListen) newListeners'
  unless (Map.null readyToServiceListeners) $ do
    mapM_ (\(k,v) -> alertListener found (k,[v])) $ Map.toList readyToServiceListeners
    end <- now
    debug $ "Immediately serviced " ++ show (Set.size noNeedToListen) ++ " listeners taking " ++ show (interval start end) ++ "mics"
  unless (Map.null realListeners) $ do
    registeredListeners %= Map.unionWith (<>) ((:[]) <$> realListeners)
    debug $ "Registered " ++ show (Map.size realListeners) ++ " listeners"
