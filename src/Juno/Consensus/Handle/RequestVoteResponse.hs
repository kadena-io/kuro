{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Consensus.Handle.RequestVoteResponse
    (handle)
where

import Control.Lens
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer.Strict
import Data.Map as Map
import Data.Set as Set

import Juno.Consensus.Handle.Types
import qualified Juno.Service.Sender as Sender
import Juno.Runtime.Timer (resetHeartbeatTimer, resetElectionTimerLeader,
                           resetElectionTimer)
import Juno.Util.Util
import qualified Juno.Types as JT

data RequestVoteResponseEnv = RequestVoteResponseEnv {
      _myNodeId :: NodeId
    , _nodeRole :: Role
    , _term :: Term
    , _lastLogIndex :: LogIndex
    , _cYesVotes :: Set.Set RequestVoteResponse
    , _quorumSize :: Int
}
makeLenses ''RequestVoteResponseEnv

data RequestVoteResponseOut =
    BecomeLeader { _newYesVotes :: Set.Set RequestVoteResponse } |
    UpdateYesVotes { _newYesVotes :: Set.Set RequestVoteResponse } |
    DeletePotentialVote { _voteNodeId :: NodeId } |
    RevertToFollower |
    NoAction

handleRequestVoteResponse :: (MonadReader RequestVoteResponseEnv m, MonadWriter [String] m) =>
                             RequestVoteResponse -> m RequestVoteResponseOut
handleRequestVoteResponse rvr@RequestVoteResponse{..} = do
  tell ["got a requestVoteResponse RPC for " ++ show (_rvrTerm, _rvrCandidateId) ++ ": " ++ show _voteGranted]
  r <- view nodeRole
  ct <- view term
  myNodeId' <- view myNodeId
  curLog <- view lastLogIndex
  if r == Candidate && ct == _rvrTerm && _rvrCandidateId == myNodeId'
  then
    if _voteGranted
    then Set.insert rvr <$> view cYesVotes >>= checkElection
    else
        return $ DeletePotentialVote _rvrNodeId
  else if ct > _rvrTerm && _rvrCurLogIndex > curLog && r == Candidate
       then do
            tell ["Log is too out of date to ever become leader, revert to last good state: "
                  ++ show (ct,curLog) ++ " vs " ++ show (_rvrTerm, _rvrCurLogIndex)]
            return RevertToFollower
       else tell ["Taking no action on RVR"] >> return NoAction


-- count the yes votes and become leader if you have reached a quorum
checkElection :: (MonadReader RequestVoteResponseEnv m, MonadWriter [String] m) =>
                 Set.Set RequestVoteResponse -> m RequestVoteResponseOut
checkElection votes = do
  nyes <- return $ Set.size votes
  qsize <- view quorumSize
  tell ["yes votes: " ++ show nyes ++ " quorum size: " ++ show qsize]
  if nyes >= qsize
  then tell ["becoming leader"] >> return (BecomeLeader votes)
  else return $ UpdateYesVotes votes


handle :: RequestVoteResponse -> JT.Raft ()
handle m = do
  r <- ask
  s <- get
  mni <- accessLogs $ JT.maxIndex
  myNodeId' <- JT.viewConfig JT.nodeId
  (o,l) <- runReaderT (runWriterT (handleRequestVoteResponse m))
           (RequestVoteResponseEnv
            (myNodeId')
            (JT._nodeRole s)
            (JT._term s)
            (mni)
            (JT._cYesVotes s)
            (JT._quorumSize r))
  mapM_ debug l
  case o of
    BecomeLeader vs -> do
             JT.cYesVotes .= vs
             becomeLeader
    UpdateYesVotes vs -> JT.cYesVotes .= vs
    DeletePotentialVote n -> JT.cPotentialVotes %= Set.delete n
    NoAction -> return ()
    RevertToFollower -> revertToLastQuorumState


-- THREAD: SERVER MAIN. updates state
becomeLeader :: JT.Raft ()
becomeLeader = do
  setRole Leader
  setCurrentLeader . Just =<< JT.viewConfig JT.nodeId
  ni <- accessLogs $ JT.entryCount
  lNextIndex' <- Map.fromSet (const $ LogIndex ni) <$> JT.viewConfig JT.otherNodes
  setLNextIndex lNextIndex'
  JT.lConvinced .= Set.empty
  enqueueRequest $ Sender.BroadcastAE Sender.SendAERegardless lNextIndex' Set.empty
  resetHeartbeatTimer
  resetElectionTimerLeader

revertToLastQuorumState :: JT.Raft ()
revertToLastQuorumState = do
  setRole Follower
  setCurrentLeader Nothing
  JT.ignoreLeader .= False
  (accessLogs $ JT.lastEntry) >>= setTerm . maybe JT.startTerm JT._leTerm
  JT.votedFor .= Nothing
  JT.cYesVotes .= Set.empty
  JT.cPotentialVotes .= Set.empty
  resetElectionTimer
