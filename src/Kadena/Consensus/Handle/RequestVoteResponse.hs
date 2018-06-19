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
import Data.Set as Set

import qualified Kadena.Config.ClusterMembership as CM
import qualified Kadena.Config.TMVar as TMV
import qualified Kadena.Sender.Service as Sender
import qualified Kadena.Types.Log as Log
import qualified Kadena.Types as KD
import Kadena.Types
import Kadena.Consensus.Util

data RequestVoteResponseEnv = RequestVoteResponseEnv {
      _myNodeId :: NodeId
    , _nodeRole :: Role
    , _term :: Term
    , _cYesVotes :: Set.Set RequestVoteResponse
    , _quorumSize :: Int
    , _icr :: Maybe InvalidCandidateResults
}
makeLenses ''RequestVoteResponseEnv

data RequestVoteResponseOut =
    BecomeLeader { _newYesVotes :: Set.Set RequestVoteResponse } |
    UpdateYesVotes { _newYesVotes :: Set.Set RequestVoteResponse } |
    UpdateInvalidCandidateResults { _invalidCandidateResults :: InvalidCandidateResults } |
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
  if r == Candidate && ct == _rvrTerm && _rvrCandidateId == myNodeId'
  then
    if _voteGranted
    then Set.insert rvr <$> view cYesVotes >>= checkElection
    else return $ DeletePotentialVote _rvrNodeId
  else if _rvrCandidateId == myNodeId' && r == Candidate
       then checkInvalids rvr
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

checkInvalids :: (MonadReader RequestVoteResponseEnv m, MonadWriter [String] m) =>
                 RequestVoteResponse -> m RequestVoteResponseOut
checkInvalids rvr@RequestVoteResponse{..} = do
  maybeIcr' <- view icr
  quorumSize' <- view quorumSize
  case maybeIcr' of
    Nothing -> error "Invariant error in checkInvalids: though I am a candidate, my Invalids were nothing!"
    Just icr'@InvalidCandidateResults{..} -> do
      case _rvrHeardFromLeader of
        Nothing -> do
          tell ["Received negative RVR but HFL was unpopulated, taking no action: " ++ show rvr]
          return NoAction
        Just HeardFromLeader{..} -> do
          if _hflYourRvSig == _icrMyReqVoteSig
          then do
            tell ["Received negative RVR with HFL populated"]
            newIcr <- return $ icr' {_icrNoVotes = Set.insert _rvrNodeId (icr' ^. icrNoVotes)}
            if Set.size (newIcr ^. icrNoVotes) >= (quorumSize' - 1)
            then do
              tell ["Reverting to follower!"]
              return $ RevertToFollower
            else do
              tell ["Not yet ready to revert"]
              return $ UpdateInvalidCandidateResults newIcr
          else do
            tell ["Negative RVR HFL but did not match: " ++ show _hflYourRvSig ++ " vs ours " ++ show _icrMyReqVoteSig]
            return NoAction



handle :: RequestVoteResponse -> KD.Consensus ()
handle m = do
  s <- get
  conf <- readConfig
  (o,l) <- runReaderT (runWriterT (handleRequestVoteResponse m))
           (RequestVoteResponseEnv
            (TMV._nodeId conf)
            (_csNodeRole s)
            (_csTerm s)
            (_csYesVotes s)
            (CM.minQuorumOthers (TMV._clusterMembers conf))
            (_csInvalidCandidateResults s))
  mapM_ debug l
  case o of
    BecomeLeader vs -> do
             csYesVotes .= vs
             becomeLeader
    UpdateYesVotes vs -> csYesVotes .= vs
    UpdateInvalidCandidateResults icr' -> csInvalidCandidateResults .= Just icr'
    DeletePotentialVote n -> csPotentialVotes %= Set.delete n
    NoAction -> return ()
    RevertToFollower -> revertToLastQuorumState


-- THREAD: SERVER MAIN. updates state
becomeLeader :: KD.Consensus ()
becomeLeader = do
  setRole Leader
  setCurrentLeader . Just =<< KD.viewConfig TMV.nodeId
  enqueueRequest $ Sender.EstablishDominance
  view KD.informEvidenceServiceOfElection >>= liftIO
  resetHeartbeatTimer
  resetElectionTimerLeader

revertToLastQuorumState :: KD.Consensus ()
revertToLastQuorumState = do
  setRole Follower
  setCurrentLeader Nothing
  csIgnoreLeader .= False
  csInvalidCandidateResults .= Nothing
  lastEntry' <- Log.hasQueryResult Log.LastEntry <$> queryLogs (Set.singleton Log.GetLastEntry)
  setTerm . maybe KD.startTerm KD._leTerm $ lastEntry'
  csVotedFor .= Nothing
  csYesVotes .= Set.empty
  csPotentialVotes .= Set.empty
  view KD.informEvidenceServiceOfElection >>= liftIO
  resetElectionTimer
