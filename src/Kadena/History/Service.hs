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

import Database.SQLite.Simple (Connection(..))

import Kadena.History.Types as X
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
  initHistoryState <- case mState of
    Nothing -> do
      pers <- setupPersistence (env ^. dbPath)
      return $! HistoryState { _registeredListeners = Map.empty, _persistence = pers }
    Just mState' -> do
      -- should we bounce the dbConn?
      return mState'
  let dbg = env ^. debugPrint
  let oChan = env ^. historyChannel
  dbg "[Histoy] Launch!"
  (_,bouncedState,_) <- runRWST (handle oChan) env initHistoryState
  runHistoryService env (Just bouncedState)

debug :: String -> HistoryService ()
debug s = do
  dbg <- view debugPrint
  liftIO $! dbg $ "[Service|History] " ++ s

now :: HistoryService UTCTime
now = view getTimestamp >>= liftIO

setupPersistence :: Maybe FilePath -> IO PersistenceSystem
setupPersistence Nothing = return $ InMemory Map.empty
setupPersistence (Just _dbPath) = error $ "History Service: on disk persistence is not yet supported"

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
  case pers of
    InMemory m -> do
      persistence .= InMemory (Map.union m $ Map.fromSet (const Nothing) srks)
      debug $ "Added " ++ show (Set.size srks) ++ " new keys"
    OnDisk dbConn -> liftIO $ insertNewKeysAsNothingSQL dbConn srks

insertNewKeysAsNothingSQL :: Connection -> Set RequestKey -> IO ()
insertNewKeysAsNothingSQL _dbConn _srks = undefined

updateExistingKeys :: Map RequestKey AppliedCommand -> HistoryService ()
updateExistingKeys updates = do
  alertListeners updates
  pers <- use persistence
  case pers of
    InMemory m -> do
      newInMem <- return $! InMemory $! foldr updateInMemKey m $ Map.toList updates
      persistence .= newInMem
      debug $ "Updated " ++ show (Map.size updates) ++ " keys"
    OnDisk dbConn -> liftIO $ updateKeysSQL dbConn updates

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
    use registeredListeners >>= debug . ("Active Listeners: " ++) . show . Map.keysSet
    end <- now
    debug $ "Serviced " ++ show (sum res) ++ " alerts taking " ++ show (interval start end) ++ "mics"

alertListener :: Map RequestKey AppliedCommand -> (RequestKey, [MVar ListenerResult]) -> HistoryService Int
alertListener res (k,mvs) = do
  commandRes <- return $! res Map.! k
  debug $ "Servicing Listener for: " ++ show k
  fails <- filter not <$> liftIO (mapM (`tryPutMVar` ListenerResult commandRes) mvs)
  unless (null fails) $ debug $ "Registered Listener Alert Failure for: " ++ show k ++ " (" ++ show (length fails) ++ " failures)"
  return $ length mvs

updateKeysSQL :: Connection -> Map RequestKey AppliedCommand -> IO ()
updateKeysSQL _dbConn _updates = undefined

queryForExisting :: (Set RequestKey, MVar ExistenceResult) -> HistoryService ()
queryForExisting (srks, mRes) = do
  pers <- use persistence
  case pers of
    InMemory m -> do
      found <- return $! Set.intersection srks $ Map.keysSet m
      liftIO $! putMVar mRes $ ExistenceResult found
    OnDisk dbConn -> do
      found <- liftIO $ queryForExistingSQL dbConn srks
      liftIO $! putMVar mRes $ ExistenceResult found

queryForExistingSQL :: Connection -> Set RequestKey -> IO (Set RequestKey)
queryForExistingSQL _dbConn _srks = undefined

queryForResults :: (Set RequestKey, MVar PossiblyIncompleteResults) -> HistoryService ()
queryForResults (srks, mRes) = do
  pers <- use persistence
  case pers of
    InMemory m -> do
      found <- return $! Map.filterWithKey (checkForIndividualResultInMem srks) m
      liftIO $! putMVar mRes $ PossiblyIncompleteResults $ fmap fromJust found
      debug $ "Querying for " ++ show (Set.size srks) ++ " keys, found " ++ show (Map.size found)
    OnDisk dbConn -> do
      found <- liftIO $ queryForResultsSQL dbConn srks
      liftIO $! putMVar mRes $ PossiblyIncompleteResults $ fmap fromJust found

-- This is here to try to get GHC to check the fast part first
checkForIndividualResultInMem :: Set RequestKey -> RequestKey -> Maybe AppliedCommand -> Bool
checkForIndividualResultInMem _ _ Nothing = False
checkForIndividualResultInMem s k (Just _) = Set.member k s

queryForResultsSQL :: Connection -> Set RequestKey -> IO (Map RequestKey (Maybe AppliedCommand))
queryForResultsSQL _dbConn _srks = undefined

registerNewListeners :: Map RequestKey (MVar ListenerResult) -> HistoryService ()
registerNewListeners newListeners' = do
  pers <- use persistence
  case pers of
    InMemory m -> do
      srks <- return $! Map.keysSet newListeners'
      found <- return $! fromJust <$> Map.filterWithKey (checkForIndividualResultInMem srks) m
      noNeedToListen <- return $! Set.intersection (Map.keysSet found) srks
      readyToServiceListeners <- return $! Map.filterWithKey (\k _ -> Set.member k noNeedToListen) newListeners'
      realListeners <- return $! Map.filterWithKey (\k _ -> not $ Set.member k noNeedToListen) newListeners'
      unless (Map.null readyToServiceListeners) $ mapM_ (\(k,v) -> alertListener found (k,[v])) $ Map.toList readyToServiceListeners
      unless (Map.null realListeners) $ registeredListeners %= Map.unionWith (<>) ((:[]) <$> realListeners)
    OnDisk dbConn -> do
      srks <- return $! Map.keysSet newListeners'
      found <- fmap fromJust <$> liftIO (queryForResultsSQL dbConn srks)
      noNeedToListen <- return $! Set.intersection (Map.keysSet found) srks
      readyToServiceListeners <- return $! Map.filterWithKey (\k _ -> Set.member k noNeedToListen) newListeners'
      realListeners <- return $! Map.filterWithKey (\k _ -> not $ Set.member k noNeedToListen) newListeners'
      unless (Map.null readyToServiceListeners) $ mapM_ (\(k,v) -> alertListener found (k,[v])) $ Map.toList readyToServiceListeners
      unless (Map.null realListeners) $ registeredListeners %= Map.unionWith (<>) ((:[]) <$> realListeners)
