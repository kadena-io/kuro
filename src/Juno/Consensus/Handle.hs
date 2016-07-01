
module Juno.Consensus.Handle
  ( handleEvents )
where

import Control.Concurrent (tryTakeMVar)
import Control.Lens hiding ((:>))
import Control.Monad
import Control.Monad.IO.Class
import Data.AffineSpace
import Data.Maybe

import Juno.Consensus.Commit (doCommit)
import Juno.Runtime.Sender (sendAllAppendEntries,sendAllAppendEntriesResponse)
import Juno.Types
import Juno.Util.Util (debug, dequeueEvent, accessLogs)

import qualified Juno.Consensus.Handle.AppendEntries as PureAppendEntries
import qualified Juno.Consensus.Handle.AppendEntriesResponse as PureAppendEntriesResponse
import qualified Juno.Consensus.Handle.Command as PureCommand
import qualified Juno.Consensus.Handle.ElectionTimeout as PureElectionTimeout
import qualified Juno.Consensus.Handle.HeartbeatTimeout as PureHeartbeatTimeout
import qualified Juno.Consensus.Handle.RequestVote as PureRequestVote
import qualified Juno.Consensus.Handle.RequestVoteResponse as PureRequestVoteResponse
import qualified Juno.Consensus.Handle.Revolution as PureRevolution

issueBatch :: Raft ()
issueBatch = do
  role' <- use nodeRole
  ci <- accessLogs $ viewLogState commitIndex
  case role' of
    Follower -> debug $ "Commit index is still: " ++ show ci
    Candidate -> return ()
    Leader -> do
      -- right now, only batch if leader
      batchTimeDelta' <- viewConfig batchTimeDelta
      curTime <- view (rs.getTimestamp) >>= liftIO
      (ts, h) <- use lLastBatchUpdate
      when (curTime .-. ts >= batchTimeDelta') $ do
        doCommit
        latestLogHash <- do {le <- accessLogs lastEntry; return $ _leHash <$> le}
        if latestLogHash /= h || isNothing latestLogHash
        then do
          sendAllAppendEntriesResponse
          sendAllAppendEntries
          curTime' <- view (rs.getTimestamp) >>= liftIO
          lLastBatchUpdate .= (curTime', h)
          debug "Batch Issuance Triggered"
        else do
          curTime' <- view (rs.getTimestamp) >>= liftIO
          lLastBatchUpdate .= (curTime', h)

handleEvents :: Raft ()
handleEvents = forever $ do
  timerTarget' <- use timerTarget
  -- we use the MVar to preempt a backlog of messages when under load. This happens during a large 'many test'
  tFired <- liftIO $ tryTakeMVar timerTarget'
  e <- case tFired of
    Nothing -> dequeueEvent
    Just v -> return v
  case e of
    ERPC rpc           -> handleRPC rpc >> issueBatch
    AERs alotOfAers    -> PureAppendEntriesResponse.handleAlotOfAers alotOfAers >> issueBatch
    ElectionTimeout s  -> PureElectionTimeout.handle s >> issueBatch
    HeartbeatTimeout s -> PureHeartbeatTimeout.handle s >> issueBatch
    Tock               -> return ()

handleRPC :: RPC -> Raft ()
handleRPC rpc = case rpc of
  AE' ae          -> PureAppendEntries.handle ae
  AER' aer        -> PureAppendEntriesResponse.handle aer
  RV' rv          -> PureRequestVote.handle rv
  RVR' rvr        -> PureRequestVoteResponse.handle rvr
  CMD' cmd        -> PureCommand.handle cmd
  CMDB' cmdb      -> PureCommand.handleBatch cmdb
  CMDR' _         -> debug "got a command response RPC"
  REV' rev        -> PureRevolution.handle rev
