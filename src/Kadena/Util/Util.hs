{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Kadena.Util.Util
  ( seqIndex
  , getQuorumSize
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
  , getCmdSigOrInvariantError
  , enqueueRequest
  , awsDashVar
  , pubConsensusFromState
  , fromMaybeM
  ) where


import Control.Concurrent (forkIO,swapMVar)
import Control.Lens
import Control.Monad.RWS.Strict
import Control.Concurrent (takeMVar, newEmptyMVar)
import qualified Control.Concurrent.Lifted as CL

import Data.Set (Set)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Map.Strict (Map)

import qualified System.Random as R
import System.Process (system)

import Kadena.Types
import qualified Kadena.Types.Service.Sender as Sender
import qualified Kadena.Service.Log as Log

awsDashVar :: Bool -> String -> String -> IO ()
awsDashVar False _ _ = return ()
awsDashVar True  k v = void $ forkIO $ void $ system $
  "aws ec2 create-tags --resources `ec2-metadata --instance-id | sed 's/^.*: //g'` --tags Key="
  ++ k
  ++ ",Value="
  ++ v
  ++ " >/dev/null"

seqIndex :: Seq a -> Int -> Maybe a
seqIndex s i =
  if i >= 0 && i < Seq.length s
    then Just (Seq.index s i)
    else Nothing

getQuorumSize :: Int -> Int
getQuorumSize n = 1 + floor (fromIntegral n / 2 :: Float)

queryLogs :: Set Log.AtomicQuery -> Consensus (Map Log.AtomicQuery Log.QueryResult)
queryLogs q = do
  enqueueLogQuery' <- view enqueueLogQuery
  mv <- liftIO newEmptyMVar
  liftIO . enqueueLogQuery' $ Log.Query q mv
  liftIO $ takeMVar mv

updateLogs :: UpdateLogs -> Consensus ()
updateLogs q = do
  enqueueLogQuery' <- view enqueueLogQuery
  liftIO . enqueueLogQuery' $ Log.Update q

debug :: String -> Consensus ()
debug s = do
  dbg <- view (rs.debugPrint)
  role' <- use nodeRole
  dontDebugFollower' <- viewConfig dontDebugFollower
  case role' of
    Leader -> liftIO $ dbg $ "[Kadena|\ESC[0;34mLEADER\ESC[0m]: " ++ s
    Follower -> liftIO $ unless dontDebugFollower' $ dbg $ "[Kadena|\ESC[0;32mFOLLOWER\ESC[0m]: " ++ s
    Candidate -> liftIO $ dbg $ "[Kadena|\ESC[1;33mCANDIDATE\ESC[0m]: " ++ s

randomRIO :: R.Random a => (a,a) -> Consensus a
randomRIO rng = view (rs.random) >>= \f -> liftIO $ f rng -- R.randomRIO

runRWS_ :: MonadIO m => RWST r w s m a -> r -> s -> m ()
runRWS_ ma r s = void $ runRWST ma r s

enqueueRequest :: Sender.ServiceRequest -> Consensus ()
enqueueRequest s = do
  sendMsg <- view sendMessage
  conf <- readConfig
  st <- get
  ss <- return $ Sender.StateSnapshot
    { Sender._newNodeId = conf ^. nodeId
    , Sender._newRole = st ^. nodeRole
    , Sender._newOtherNodes = conf ^. otherNodes
    , Sender._newLeader = st ^. currentLeader
    , Sender._newTerm = st ^. term
    , Sender._newPublicKey = conf ^. myPublicKey
    , Sender._newPrivateKey = conf ^. myPrivateKey
    , Sender._newYesVotes = st ^. cYesVotes
    }
  liftIO $ sendMsg $ Sender.ServiceRequest' ss s

-- no state update
enqueueEvent :: Event -> Consensus ()
enqueueEvent event = view enqueue >>= \f -> liftIO $ f event
  -- lift $ writeChan ein event

enqueueEventLater :: Int -> Event -> Consensus CL.ThreadId
enqueueEventLater t event = view enqueueLater >>= \f -> liftIO $ f t event

-- no state update
dequeueEvent :: Consensus Event
dequeueEvent = view dequeue >>= \f -> liftIO f


logMetric :: Metric -> Consensus ()
logMetric metric = view (rs.publishMetric) >>= \f -> liftIO $ f metric

logStaticMetrics :: Consensus ()
logStaticMetrics = do
  logMetric . MetricNodeId =<< viewConfig nodeId
  logMetric . MetricClusterSize =<< view clusterSize
  logMetric . MetricQuorumSize =<< view quorumSize


fromMaybeM :: Monad m => m b -> Maybe b -> m b
fromMaybeM errM = maybe errM (return $!)

publishConsensus :: Consensus ()
publishConsensus = do
  cs <- get
  p <- view mPubConsensus
  liftIO $ void $ swapMVar p $ pubConsensusFromState cs

pubConsensusFromState :: ConsensusState -> PublishedConsensus
pubConsensusFromState ConsensusState {..} = PublishedConsensus _currentLeader _nodeRole _term

setTerm :: Term -> Consensus ()
setTerm t = do
  term .= t
  publishConsensus
  logMetric $ MetricTerm t

setRole :: Role -> Consensus ()
setRole newRole = do
  nodeRole .= newRole
  publishConsensus
  logMetric $ MetricRole newRole

setCurrentLeader :: Maybe NodeId -> Consensus ()
setCurrentLeader mNode = do
  currentLeader .= mNode
  publishConsensus
  logMetric $ MetricCurrentLeader mNode

getCmdSigOrInvariantError :: String -> Command -> Signature
getCmdSigOrInvariantError where' s@Command{..} = case _cmdProvenance of
  NewMsg -> error $ where'
    ++ ": This should be unreachable, somehow an AE got through with a LogEntry that contained an unsigned Command" ++ show s
  ReceivedMsg{..} -> _digSig _pDig
