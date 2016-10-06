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

import qualified Data.Map.Strict as Map
import Data.Thyme.Clock
import Data.Maybe (fromJust)

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

--data PersistenceSystem =
--  InMemory
--    {inMemResults :: !(Map RequestKey (Maybe CommandResult))} |
--  OnDisk
--    {dbConn :: !Connection}
--
--data HistoryState = HistoryState
--  { _registeredListeners :: !(Map RequestKey [MVar ListenerResult])
--  , _persistence :: !PersistenceSystem
--  }

runHistoryService :: HistoryEnv -> Maybe HistoryState -> IO ()
runHistoryService env Nothing = do
  pers <- setupPersistence (env ^. dbPath)
  initHistoryState <- return $! HistoryState { _registeredListeners = Map.empty, _persistence = pers }
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
setupPersistence = undefined

handle :: HistoryChannel -> HistoryService ()
handle oChan = do
  q <- liftIO $ readComm oChan
  unless (q == Bounce) $ do
    case q of
      Tick t -> liftIO (pprintTock t) >>= debug
      AddNew{..} -> undefined -- { hNewKeys :: !(Set RequestKey) }
      Update{..} -> undefined -- { hUpdateRks :: !(Map RequestKey CommandResult) }
      QueryForExistence{..} -> undefined -- { hQueryForExistence :: !(Set RequestKey, MVar ExistenceResult) }
      QueryForResults{..} -> undefined -- { hQueryForResults :: !(RequestKey, MVar PossiblyIncompleteResults) }
      RegisterListener{..} -> undefined -- { hNewListener :: !(RequestKey, MVar ListenerResult)}
    handle oChan
