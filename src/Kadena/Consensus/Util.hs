module Kadena.Consensus.Util
  ( resetElectionTimer
  , resetElectionTimerLeader
  , resetHeartbeatTimer
  , hasElectionTimerLeaderFired
  , cancelTimer
  , becomeFollower
  ) where

import Control.Monad.IO.Class
import Control.Lens hiding (Index)
import Kadena.Types
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
