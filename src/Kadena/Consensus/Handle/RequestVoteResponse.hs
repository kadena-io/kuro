{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Consensus.Handle.RequestVoteResponse
    (handle)
where

import Control.Lens
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer.Strict
-- import Data.Map as Map
import Data.Set as Set

import Kadena.Consensus.Handle.Types
import qualified Kadena.Service.Sender as Sender
import qualified Kadena.Service.Log as Log
import Kadena.Runtime.Timer (resetHeartbeatTimer, resetElectionTimerLeader,
                           resetElectionTimer)
import Kadena.Util.Util
import qualified Kadena.Types as KD

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


handle :: RequestVoteResponse -> KD.Raft ()
handle m = do
  r <- ask
  s <- get
  mni <- Log.hasQueryResult Log.MaxIndex <$> (queryLogs $ Set.fromList [Log.GetMaxIndex])
  myNodeId' <- KD.viewConfig KD.nodeId
  (o,l) <- runReaderT (runWriterT (handleRequestVoteResponse m))
           (RequestVoteResponseEnv
            (myNodeId')
            (KD._nodeRole s)
            (KD._term s)
            (mni)
            (KD._cYesVotes s)
            (KD._quorumSize r))
  mapM_ debug l
  case o of
    BecomeLeader vs -> do
             KD.cYesVotes .= vs
             becomeLeader
    UpdateYesVotes vs -> KD.cYesVotes .= vs
    DeletePotentialVote n -> KD.cPotentialVotes %= Set.delete n
    NoAction -> return ()
    RevertToFollower -> revertToLastQuorumState


-- THREAD: SERVER MAIN. updates state
becomeLeader :: KD.Raft ()
becomeLeader = do
  setRole Leader
  setCurrentLeader . Just =<< KD.viewConfig KD.nodeId
--  mv <- queryLogs $ Set.fromList [Log.GetEntryCount, Log.GetCommitIndex]
--  ni <- return $ Log.hasQueryResult Log.EntryCount mv
--  ci <- return $ Log.hasQueryResult Log.CommitIndex mv
--  lNextIndex' <- Map.fromSet (const $ LogIndex ni) <$> KD.viewConfig KD.otherNodes
--  setLNextIndex ci lNextIndex'
--  KD.lConvinced .= Set.empty
  enqueueRequest $ Sender.EstablishDominance
  view KD.informEvidenceServiceOfElection >>= liftIO
  resetHeartbeatTimer
  resetElectionTimerLeader

revertToLastQuorumState :: KD.Raft ()
revertToLastQuorumState = do
  setRole Follower
  setCurrentLeader Nothing
  KD.ignoreLeader .= False
  lastEntry' <- Log.hasQueryResult Log.LastEntry <$> (queryLogs $ Set.singleton Log.GetLastEntry)
  setTerm . maybe KD.startTerm KD._leTerm $ lastEntry'
  KD.votedFor .= Nothing
  KD.cYesVotes .= Set.empty
  KD.cPotentialVotes .= Set.empty
  view KD.informEvidenceServiceOfElection >>= liftIO
  resetElectionTimer
