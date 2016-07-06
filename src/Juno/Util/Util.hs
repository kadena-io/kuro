{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Juno.Util.Util
  ( seqIndex
  , getQuorumSize
  , accessLogs
  , getLogState
  , debug
  , randomRIO
  , runRWS_
  , enqueueEvent, enqueueEventLater
  , dequeueEvent
  , dequeueCommand
  , logMetric
  , logStaticMetrics
  , setTerm
  , setRole
  , setCurrentLeader
  , updateLNextIndex
  , setLNextIndex
  , getCmdSigOrInvariantError
  , getRevSigOrInvariantError
  , enqueueRequest
  ) where


import Control.Lens
import Control.Monad.RWS.Strict
import qualified Control.Concurrent.Lifted as CL

import Data.IORef
import qualified System.Random as R

import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Map.Strict as Map

import Juno.Types
import qualified Juno.Types.Sender as Sender
import Juno.Util.Combinator

seqIndex :: Seq a -> Int -> Maybe a
seqIndex s i =
  if i >= 0 && i < Seq.length s
    then Just (Seq.index s i)
    else Nothing

getQuorumSize :: Int -> Int
getQuorumSize n = 1 + floor (fromIntegral n / 2 :: Float)

accessLogs :: (IORef (LogState LogEntry) -> IO b) -> Raft b
accessLogs cmd = view logThread >>= liftIO . cmd

getLogState :: Raft (LogState LogEntry)
getLogState = view logThread >>= liftIO . readIORef

debug :: String -> Raft ()
debug s = do
  dbg <- view (rs.debugPrint)
  nid <- viewConfig nodeId
  role' <- use nodeRole
  dontDebugFollower' <- viewConfig dontDebugFollower
  case role' of
    Leader -> liftIO $ dbg nid $ "\ESC[0;34m[LEADER]\ESC[0m: " ++ s
    Follower -> liftIO $ when (not dontDebugFollower') $ dbg nid $ "\ESC[0;32m[FOLLOWER]\ESC[0m: " ++ s
    Candidate -> liftIO $ dbg nid $ "\ESC[1;33m[CANDIDATE]\ESC[0m: " ++ s

randomRIO :: R.Random a => (a,a) -> Raft a
randomRIO rng = view (rs.random) >>= \f -> liftIO $ f rng -- R.randomRIO

runRWS_ :: MonadIO m => RWST r w s m a -> r -> s -> m ()
runRWS_ ma r s = void $ runRWST ma r s

enqueueRequest :: Sender.ServiceRequest -> Raft ()
enqueueRequest s = do
  sendMsg <- view sendMessage
  liftIO $ sendMsg s

-- no state update
enqueueEvent :: Event -> Raft ()
enqueueEvent event = view (enqueue) >>= \f -> liftIO $ f event
  -- lift $ writeChan ein event

enqueueEventLater :: Int -> Event -> Raft CL.ThreadId
enqueueEventLater t event = view (enqueueLater) >>= \f -> liftIO $ f t event

-- no state update
dequeueEvent :: Raft Event
dequeueEvent = view (dequeue) >>= \f -> liftIO f

-- dequeue command from API interface
dequeueCommand :: Raft (RequestId, [(Maybe Alias, CommandEntry)])
dequeueCommand = view (rs.dequeueFromApi) >>= \f -> liftIO f

logMetric :: Metric -> Raft ()
logMetric metric = view (rs.publishMetric) >>= \f -> liftIO $ f metric

logStaticMetrics :: Raft ()
logStaticMetrics = do
  logMetric . MetricNodeId =<< viewConfig nodeId
  logMetric . MetricClusterSize =<< view clusterSize
  logMetric . MetricQuorumSize =<< view quorumSize


setTerm :: Term -> Raft ()
setTerm t = do
  void $ rs.writeTermNumber ^$ t
  term .= t
  logMetric $ MetricTerm t

setRole :: Role -> Raft ()
setRole newRole = do
  nodeRole .= newRole
  logMetric $ MetricRole newRole

setCurrentLeader :: Maybe NodeId -> Raft ()
setCurrentLeader mNode = do
  currentLeader .= mNode
  logMetric $ MetricCurrentLeader mNode

updateLNextIndex :: (Map.Map NodeId LogIndex -> Map.Map NodeId LogIndex)
                 -> Raft ()
updateLNextIndex f = do
  lNextIndex %= f
  lni <- use lNextIndex
  ci <- accessLogs $ viewLogState commitIndex
  logMetric $ MetricAvailableSize $ availSize lni ci

  where
    -- | The number of nodes at most one behind the commit index
    availSize lni ci = let oneBehind = pred ci
                       in succ $ Map.size $ Map.filter (>= oneBehind) lni

setLNextIndex :: Map.Map NodeId LogIndex
              -> Raft ()
setLNextIndex = updateLNextIndex . const

getCmdSigOrInvariantError :: String -> Command -> Signature
getCmdSigOrInvariantError where' s@Command{..} = case _cmdProvenance of
  NewMsg -> error $ where'
    ++ ": This should be unreachable, somehow an AE got through with a LogEntry that contained an unsigned Command" ++ show s
  ReceivedMsg{..} -> _digSig _pDig

getRevSigOrInvariantError :: String -> Revolution -> Signature
getRevSigOrInvariantError where' s@Revolution{..} = case _revProvenance of
  NewMsg -> error $ where'
    ++ ": This should be unreachable, got an unsigned Revolution" ++ show s
  ReceivedMsg{..} -> _digSig _pDig
