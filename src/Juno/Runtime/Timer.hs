module Juno.Runtime.Timer
  ( resetElectionTimer
  , resetElectionTimerLeader
  , resetHeartbeatTimer
  , hasElectionTimerLeaderFired
  , cancelTimer
  ) where

import Control.Monad.IO.Class
import Control.Lens hiding (Index)
import Juno.Types
import Juno.Util.Util

getNewElectionTimeout :: Raft Int
getNewElectionTimeout = viewConfig electionTimeoutRange >>= randomRIO

resetElectionTimer :: Raft ()
resetElectionTimer = do
  timeout <- getNewElectionTimeout
  debug $ "Reset Election Timeout: " ++ show (timeout `div` 1000) ++ "ms"
  setTimedEvent (ElectionTimeout $ show (timeout `div` 1000) ++ "ms") timeout

hasElectionTimerLeaderFired :: Raft Bool
hasElectionTimerLeaderFired = do
  maxTimeout <- ((*2) . snd) <$> viewConfig electionTimeoutRange
  timeSinceLastAER' <- use timeSinceLastAER
  return $ timeSinceLastAER' >= maxTimeout

resetElectionTimerLeader :: Raft ()
resetElectionTimerLeader = timeSinceLastAER .= 0

resetHeartbeatTimer :: Raft ()
resetHeartbeatTimer = do
  timeout <- viewConfig heartbeatTimeout
  debug $ "Reset Heartbeat Timeout: " ++ show (timeout `div` 1000) ++ "ms"
  setTimedEvent (HeartbeatTimeout $ show (timeout `div` 1000) ++ "ms") timeout

cancelTimer :: Raft ()
cancelTimer = do
  tmr <- use timerThread
  case tmr of
    Nothing -> return ()
    Just t -> view killEnqueued >>= \f -> liftIO $ f t
  timerThread .= Nothing

setTimedEvent :: Event -> Int -> Raft ()
setTimedEvent e t = do
  cancelTimer
  tmr <- enqueueEventLater t e -- forks, no state
  timerThread .= Just tmr
