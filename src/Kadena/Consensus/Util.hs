{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Consensus.Util
  ( resetElectionTimer
  , resetElectionTimerLeader
  , resetHeartbeatTimer
  , hasElectionTimerLeaderFired
  , cancelTimer
  , becomeFollower
  , queryLogs
  , updateLogs
  , debug
  , randomRIO
  , runRWS_
  , enqueueEvent, enqueueEventLater
  , dequeueEvent
  , logMetric
  , logStaticMetrics
  , setTerm
  , setRole
  , setCurrentLeader
  , enqueueRequest
  , enqueueRequest'
  , sendHistoryNewKeys
  , queryHistoryForExisting
  , queryHistoryForPriorApplication
  , now
  ) where

import Control.Lens hiding (Index)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.RWS.Strict
import Control.Concurrent (putMVar, takeMVar, newEmptyMVar)
import qualified Control.Concurrent.Lifted as CL

import Data.HashSet (HashSet)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map.Strict (Map)

import Data.Thyme.Clock
import qualified System.Random as R

import Kadena.Types
import qualified Kadena.Sender.Types as Sender
import qualified Kadena.Log.Types as Log
import qualified Kadena.Types.Log as Log
import qualified Kadena.History.Types as History
import Kadena.Util.Util

getNewElectionTimeout :: Consensus Int
getNewElectionTimeout = viewConfig electionTimeoutRange >>= randomRIO

resetElectionTimer :: Consensus ()
resetElectionTimer = do
  timeout <- getNewElectionTimeout
  debug $ "Reset Election Timeout: " ++ show (timeout `div` 1000) ++ "ms"
  setTimedEvent (ElectionTimeout $ show (timeout `div` 1000) ++ "ms") timeout

-- | If a leader hasn't heard from a follower in longer than 2x max election timeouts, he should step down.
hasElectionTimerLeaderFired :: Consensus Bool
hasElectionTimerLeaderFired = do
  maxTimeout <- ((*2) . snd) <$> viewConfig electionTimeoutRange
  timeSinceLastAER' <- use timeSinceLastAER
  return $ timeSinceLastAER' >= maxTimeout

resetElectionTimerLeader :: Consensus ()
resetElectionTimerLeader = timeSinceLastAER .= 0

resetHeartbeatTimer :: Consensus ()
resetHeartbeatTimer = do
  timeout <- viewConfig heartbeatTimeout
  debug $ "Reset Heartbeat Timeout: " ++ show (timeout `div` 1000) ++ "ms"
  setTimedEvent (HeartbeatTimeout $ show (timeout `div` 1000) ++ "ms") timeout

cancelTimer :: Consensus ()
cancelTimer = do
  tmr <- use timerThread
  case tmr of
    Nothing -> return ()
    Just t -> view killEnqueued >>= \f -> liftIO $ f t
  timerThread .= Nothing

setTimedEvent :: Event -> Int -> Consensus ()
setTimedEvent e t = do
  cancelTimer
  tmr <- enqueueEventLater t e -- forks, no state
  timerThread .= Just tmr

becomeFollower :: Consensus ()
becomeFollower = do
  debug "becoming follower"
  setRole Follower
  resetElectionTimer

queryLogs :: Set Log.AtomicQuery -> Consensus (Map Log.AtomicQuery Log.QueryResult)
queryLogs q = do
  enqueueLogQuery' <- view enqueueLogQuery
  mv <- liftIO newEmptyMVar
  liftIO . enqueueLogQuery' $! Log.Query q mv
  liftIO $! takeMVar mv

updateLogs :: UpdateLogs -> Consensus ()
updateLogs q = do
  enqueueLogQuery' <- view enqueueLogQuery
  liftIO . enqueueLogQuery' $! Log.Update q

debug :: String -> Consensus ()
debug s = do
  dbg <- view (rs.debugPrint)
  role' <- use nodeRole
  case role' of
    Leader -> liftIO $! dbg $! "[Kadena|\ESC[0;34mLEADER\ESC[0m]: " ++ s
    Follower -> liftIO $! dbg $! "[Kadena|\ESC[0;32mFOLLOWER\ESC[0m]: " ++ s
    Candidate -> liftIO $! dbg $! "[Kadena|\ESC[1;33mCANDIDATE\ESC[0m]: " ++ s

randomRIO :: R.Random a => (a,a) -> Consensus a
randomRIO rng = view (rs.random) >>= \f -> liftIO $! f rng -- R.randomRIO


-- TODO: refactor this so that sender service can directly query for the state it needs
enqueueRequest :: Sender.ServiceRequest -> Consensus ()
enqueueRequest s = do
  sendMsg <- view sendMessage
  conf <- readConfig
  st <- get
  ss <- return $! Sender.StateSnapshot
    { Sender._snapNodeId = conf ^. nodeId
    , Sender._snapNodeRole = st ^. nodeRole
    , Sender._snapOtherNodes = conf ^. otherNodes
    , Sender._snapLeader = st ^. currentLeader
    , Sender._snapTerm = st ^. term
    , Sender._snapPublicKey = conf ^. myPublicKey
    , Sender._snapPrivateKey = conf ^. myPrivateKey
    , Sender._snapYesVotes = st ^. cYesVotes
    }
  liftIO $! sendMsg $! Sender.ServiceRequest' ss s

enqueueRequest' :: Sender.ServiceRequest' -> Consensus ()
enqueueRequest' s = do
  sendMsg <- view sendMessage
  liftIO $! sendMsg s

-- no state update
enqueueEvent :: Event -> Consensus ()
enqueueEvent event = view enqueue >>= \f -> liftIO $! f event

enqueueEventLater :: Int -> Event -> Consensus CL.ThreadId
enqueueEventLater t event = view enqueueLater >>= \f -> liftIO $! f t event

-- no state update
dequeueEvent :: Consensus Event
dequeueEvent = view dequeue >>= \f -> liftIO f

logMetric :: Metric -> Consensus ()
logMetric metric = view (rs.publishMetric) >>= \f -> liftIO $! f metric

logStaticMetrics :: Consensus ()
logStaticMetrics = do
  Config{..} <- readConfig
  logMetric . MetricNodeId =<< viewConfig nodeId
  logMetric $ MetricClusterSize (1 + Set.size _otherNodes)
  logMetric . MetricQuorumSize $ getQuorumSize (Set.size _otherNodes)

-- NB: Yes, the strictness here is probably overkill, but this used to leak the bloom filter
publishConsensus :: Consensus ()
publishConsensus = do
  !currentLeader' <- use currentLeader
  !nodeRole' <- use nodeRole
  !term' <- use term
  !cYesVotes' <- use cYesVotes
  p <- view mPubConsensus
  newPubCons <- return $! PublishedConsensus currentLeader' nodeRole' term' cYesVotes'
  _ <- liftIO $! takeMVar p
  liftIO $! putMVar p $! newPubCons

setTerm :: Term -> Consensus ()
setTerm t = do
  term .= t
  publishConsensus
  logMetric $! MetricTerm t

setRole :: Role -> Consensus ()
setRole newRole = do
  nodeRole .= newRole
  publishConsensus
  logMetric $! MetricRole newRole

setCurrentLeader :: Maybe NodeId -> Consensus ()
setCurrentLeader mNode = do
  currentLeader .= mNode
  publishConsensus
  logMetric $! MetricCurrentLeader mNode

runRWS_ :: MonadIO m => RWST r w s m a -> r -> s -> m ()
runRWS_ ma r s = void $! runRWST ma r s


--newtype ExistenceResult = ExistenceResult
--  { rksThatAlreadyExist :: Set RequestKey
--  } deriving (Show, Eq)
--
--newtype PossiblyIncompleteResults = PossiblyIncompleteResults
--  { possiblyIncompleteResults :: Map RequestKey CommandResult
--  } deriving (Show, Eq)
--
--data ListenerResult =
--  ListenerResult CommandResult |
--  GCed
--  deriving (Show, Eq)
--
--data History =
--  AddNew
--    { hNewKeys :: !(Set RequestKey) } |
--  Update
--    { hUpdateRks :: !(Map RequestKey CommandResult) } |
--  QueryForExistence
--    { hQueryForExistence :: !(Set RequestKey, MVar ExistenceResult) } |
--  QueryForResults
--    { hQueryForResults :: !(Set RequestKey, MVar PossiblyIncompleteResults) } |
--  RegisterListener
--    { hNewListener :: !(Map RequestKey (MVar ListenerResult))} |
--  Bounce |
--  Heart Beat
--  deriving (Eq)

sendHistoryNewKeys :: HashSet RequestKey -> Consensus ()
sendHistoryNewKeys srks = do
  send <- view enqueueHistoryQuery
  liftIO $ send $ History.AddNew srks

queryHistoryForExisting :: HashSet RequestKey -> Consensus (HashSet RequestKey)
queryHistoryForExisting srks = do
  send <- view enqueueHistoryQuery
  m <- liftIO $ newEmptyMVar
  liftIO $ send $ History.QueryForExistence (srks,m)
  History.ExistenceResult{..} <- liftIO $ takeMVar m
  return rksThatAlreadyExist

queryHistoryForPriorApplication :: HashSet RequestKey -> Consensus (HashSet RequestKey)
queryHistoryForPriorApplication srks = do
  send <- view enqueueHistoryQuery
  m <- liftIO $ newEmptyMVar
  liftIO $ send $ History.QueryForPriorApplication (srks,m)
  History.ExistenceResult{..} <- liftIO $ takeMVar m
  return rksThatAlreadyExist

now :: Consensus UTCTime
now = view (rs.getTimestamp) >>= liftIO
