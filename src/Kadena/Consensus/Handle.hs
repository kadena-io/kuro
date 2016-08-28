
module Kadena.Consensus.Handle
  ( handleEvents )
where

import Control.Concurrent (tryTakeMVar)
import Control.Lens hiding ((:>))
import Control.Monad
import Control.Monad.IO.Class

import Data.Maybe (fromJust)

import Kadena.Types
import Kadena.Util.Util (debug, dequeueEvent)
import Kadena.Consensus.Commit (applyLogEntries)
import qualified Kadena.Types.Log as Log

import qualified Kadena.Consensus.Handle.AppendEntries as PureAppendEntries
import qualified Kadena.Consensus.Handle.Command as PureCommand
import qualified Kadena.Consensus.Handle.ElectionTimeout as PureElectionTimeout
import qualified Kadena.Consensus.Handle.HeartbeatTimeout as PureHeartbeatTimeout
import qualified Kadena.Consensus.Handle.RequestVote as PureRequestVote
import qualified Kadena.Consensus.Handle.RequestVoteResponse as PureRequestVoteResponse
import qualified Kadena.Consensus.Handle.Revolution as PureRevolution

handleEvents :: Consensus ()
handleEvents = forever $ do
  timerTarget' <- use timerTarget
  -- we use the MVar to preempt a backlog of messages when under load. This happens during a large 'many test'
  tFired <- liftIO $ tryTakeMVar timerTarget'
  e <- case tFired of
    Nothing -> dequeueEvent
    Just v -> return v
  case e of
    ERPC rpc                      -> handleRPC rpc
    ElectionTimeout s             -> PureElectionTimeout.handle s
    HeartbeatTimeout s            -> PureHeartbeatTimeout.handle s
    ApplyLogEntries unappliedEntries' -> do
      debug $ (show . Log.lesCnt $ unappliedEntries')
            ++ " new log entries to apply, up to "
            ++ show (fromJust $ Log.lesMaxIndex unappliedEntries')
      applyLogEntries unappliedEntries'
    Tick tock'                    -> liftIO (pprintTock tock') >>= debug

-- TODO: prune out AER's from RPC if possible
handleRPC :: RPC -> Consensus ()
handleRPC rpc = case rpc of
  AE' ae          -> PureAppendEntries.handle ae
  AER' aer        -> error $ "Invariant Error: AER received by Consensus Service" ++ show aer
  RV' rv          -> PureRequestVote.handle rv
  RVR' rvr        -> PureRequestVoteResponse.handle rvr
  CMD' cmd        -> PureCommand.handle cmd
  CMDB' cmdb      -> PureCommand.handleBatch cmdb
  CMDR' _         -> debug "got a command response RPC"
  REV' rev        -> PureRevolution.handle rev