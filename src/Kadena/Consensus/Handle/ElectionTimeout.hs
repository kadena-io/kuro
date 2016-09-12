{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Consensus.Handle.ElectionTimeout
    (handle)
    where

import Control.Lens
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer

import Data.Set (Set)
import qualified Data.Set as Set

import Kadena.Consensus.Handle.Types
import qualified Kadena.Service.Sender as Sender
import qualified Kadena.Service.Log as Log
import Kadena.Runtime.Timer (resetElectionTimer, hasElectionTimerLeaderFired)
import Kadena.Util.Util

import qualified Kadena.Types as KD

data ElectionTimeoutEnv = ElectionTimeoutEnv {
      _nodeRole :: Role
    , _term :: Term
    , _lazyVote :: Maybe LazyVote
    , _nodeId :: NodeId
    , _otherNodes :: Set.Set NodeId
    , _leaderWithoutFollowers :: Bool
    , _myPrivateKey :: PrivateKey
    , _myPublicKey :: PublicKey
    , _maxIndex :: LogIndex
    }
makeLenses ''ElectionTimeoutEnv

data ElectionTimeoutOut =
    AlreadyLeader |
    VoteForLazyCandidate {
      _newTerm :: Term
    , _lazyCandidate :: NodeId
    , _myLazyVote :: Bool
    } |
    AbdicateAndLazyVote {
      _newTerm :: Term
    , _lazyCandidate :: NodeId
    , _myLazyVote :: Bool
    } |
    BecomeCandidate {
      _newTerm :: Term
    , _newRole :: Role
    , _myNodeId :: NodeId -- just to be explicit, obviously it's us
    , _lastLogIndex :: LogIndex
    , _potentialVotes :: Set.Set NodeId
    , _yesVotes :: Set RequestVoteResponse
    }

handleElectionTimeout :: (MonadReader ElectionTimeoutEnv m, MonadWriter [String] m) => String -> m ElectionTimeoutOut
handleElectionTimeout s = do
  tell ["election timeout: " ++ s]
  r <- view nodeRole
  leaderWithoutFollowers' <- view leaderWithoutFollowers
  if r /= Leader
  then do
    lv <- view lazyVote
    case lv of
      Just LazyVote{..} -> do
        return $ VoteForLazyCandidate (_lvVoteFor ^. rvTerm) (_lvVoteFor ^. rvCandidateId) True
      Nothing -> becomeCandidate
  else if r == Leader && leaderWithoutFollowers'
       then do
            lv <- view lazyVote
            case lv of
              Just LazyVote{..} -> do
                return $ AbdicateAndLazyVote (_lvVoteFor ^. rvTerm) (_lvVoteFor ^. rvCandidateId) True
              Nothing -> becomeCandidate
       else return AlreadyLeader

-- THREAD: SERVER MAIN. updates state
becomeCandidate :: (MonadReader ElectionTimeoutEnv m, MonadWriter [String] m) => m ElectionTimeoutOut
becomeCandidate = do
  tell ["becoming candidate"]
  newTerm <- (+1) <$> view term
  me <- view nodeId
  selfVote <- return $ createRequestVoteResponse me me newTerm True
  -- TODO: Track Sig for RV/initialize invalidCandidateResults
  provenance <- selfVoteProvenance selfVote
  potentials <- view otherNodes
  return $ BecomeCandidate
    { _newTerm = newTerm
    , _newRole = Candidate
    , _myNodeId = me
    , _lastLogIndex = maxIndex'
    , _potentialVotes = potentials
    , _yesVotes = Set.singleton (selfVote {_rvrProvenance = provenance})}

-- we need to actually sign this one now, or else we'll end up signing it every time we transmit it as evidence (i.e. every AE)
selfVoteProvenance :: (MonadReader ElectionTimeoutEnv m, MonadWriter [String] m) => RequestVoteResponse -> m Provenance
selfVoteProvenance rvr = do
  nodeId' <- view nodeId
  myPrivateKey' <- view myPrivateKey
  myPublicKey' <- view myPublicKey
  (SignedRPC dig bdy) <- return $ toWire nodeId' myPublicKey' myPrivateKey' rvr
  return $ ReceivedMsg dig bdy Nothing

handle :: String -> KD.Consensus ()
handle msg = do
  c <- KD.readConfig
  s <- get
  leaderWithoutFollowers' <- hasElectionTimerLeaderFired
  maxIndex' <- Log.hasQueryResult Log.MaxIndex <$> (queryLogs $ Set.singleton Log.GetMaxIndex)
  (out,l) <- runReaderT (runWriterT (handleElectionTimeout msg)) $
             ElectionTimeoutEnv
             (KD._nodeRole s)
             (KD._term s)
             (KD._lazyVote s)
             (KD._nodeId c)
             (KD._otherNodes c)
             leaderWithoutFollowers'
             (KD._myPrivateKey c)
             (KD._myPublicKey c)
             (maxIndex')
  mapM_ debug l
  case out of
    AlreadyLeader -> return ()
    -- this is for handling the leader w/o followers case only
    AbdicateAndLazyVote {..} -> do
      castLazyVote _newTerm _lazyCandidate
    VoteForLazyCandidate {..} -> castLazyVote _newTerm _lazyCandidate
    BecomeCandidate {..} -> do
               setRole _newRole
               setTerm _newTerm
               setVotedFor (Just _myNodeId)
               selfYesVote <- return $ createRequestVoteResponse _myNodeId _myNodeId _newTerm True
               KD.cYesVotes .= Set.singleton selfYesVote
               KD.cPotentialVotes.= _potentialVotes
               enqueueRequest $ Sender.BroadcastRV
               view KD.informEvidenceServiceOfElection >>= liftIO
               resetElectionTimer

castLazyVote :: Term -> NodeId -> KD.Consensus ()
castLazyVote lazyTerm' lazyCandidate' = do
  setTerm lazyTerm'
  setVotedFor (Just lazyCandidate')
  KD.lazyVote .= Nothing
  KD.ignoreLeader .= False
  setCurrentLeader Nothing
  enqueueRequest $ Sender.BroadcastRVR lazyCandidate' Nothing True
  -- TODO: we need to verify that this is correct. It seems that a RVR (so a vote) is sent every time an election timeout fires.
  -- However, should that be the case? I think so, as you shouldn't vote for multiple people in the same election. Still though...
  resetElectionTimer

-- THREAD: SERVER MAIN. updates state
setVotedFor :: Maybe NodeId -> KD.Consensus ()
setVotedFor mvote = do
  KD.votedFor .= mvote

createRequestVoteResponse :: NodeId -> NodeId -> Term -> Bool -> RequestVoteResponse
createRequestVoteResponse me' target' term' vote =
  RequestVoteResponse term' Nothing me' vote target' NewMsg
