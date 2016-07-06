{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Consensus.Handle.ElectionTimeout
    (handle)
    where

import Control.Lens
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer

import Data.Set (Set)
import qualified Data.Set as Set

import Juno.Consensus.Handle.Types
import qualified Juno.Types.Sender as Sender
import Juno.Runtime.Timer (resetElectionTimer, hasElectionTimerLeaderFired)
import Juno.Types.Log hiding (logEntries)
import Juno.Util.Combinator ((^$))
import Juno.Util.Util

import qualified Juno.Types as JT

data ElectionTimeoutEnv = ElectionTimeoutEnv {
      _nodeRole :: Role
    , _term :: Term
    , _lazyVote :: Maybe (Term,NodeId,LogIndex)
    , _nodeId :: NodeId
    , _otherNodes :: Set.Set NodeId
    , _logEntries :: LogState LogEntry
    , _leaderWithoutFollowers :: Bool
    , _myPrivateKey :: PrivateKey
    , _myPublicKey :: PublicKey
    }
makeLenses ''ElectionTimeoutEnv

data ElectionTimeoutOut =
    AlreadyLeader |
    VoteForLazyCandidate {
      _newTerm :: Term
    , _lazyCandidate :: NodeId
    , _lastLogIndex :: LogIndex
    , _myLazyVote :: Bool
    } |
    AbdicateAndLazyVote {
      _newTerm :: Term
    , _lazyCandidate :: NodeId
    , _lastLogIndex :: LogIndex
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
      Just (lazyTerm, lazyCandidate, lastLogIndex') -> do
        return $ VoteForLazyCandidate lazyTerm lazyCandidate lastLogIndex' True
      Nothing -> becomeCandidate
  else if r == Leader && leaderWithoutFollowers'
       then do
            lv <- view lazyVote
            case lv of
              Just (lazyTerm, lazyCandidate, lastLogIndex') -> do
                return $ AbdicateAndLazyVote lazyTerm lazyCandidate lastLogIndex' True
              Nothing -> becomeCandidate
       else return AlreadyLeader

-- THREAD: SERVER MAIN. updates state
becomeCandidate :: (MonadReader ElectionTimeoutEnv m, MonadWriter [String] m) => m ElectionTimeoutOut
becomeCandidate = do
  tell ["becoming candidate"]
  newTerm <- (+1) <$> view term
  me <- view nodeId
  es <- view logEntries
  selfVote <- return $ createRequestVoteResponse me me newTerm (maxIndex' es) True
  provenance <- selfVoteProvenance selfVote
  potentials <- view otherNodes
  return $ BecomeCandidate
    { _newTerm = newTerm
    , _newRole = Candidate
    , _myNodeId = me
    , _lastLogIndex = maxIndex' es
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

handle :: String -> JT.Raft ()
handle msg = do
  c <- JT.readConfig
  s <- get
  leaderWithoutFollowers' <- hasElectionTimerLeaderFired
  ls <- getLogState
  (out,l) <- runReaderT (runWriterT (handleElectionTimeout msg)) $
             ElectionTimeoutEnv
             (JT._nodeRole s)
             (JT._term s)
             (JT._lazyVote s)
             (JT._nodeId c)
             (JT._otherNodes c)
             (ls)
             leaderWithoutFollowers'
             (JT._myPrivateKey c)
             (JT._myPublicKey c)
  mapM_ debug l
  case out of
    AlreadyLeader -> return ()
    -- this is for handling the leader w/o followers case only
    AbdicateAndLazyVote {..} -> do
      castLazyVote _newTerm _lazyCandidate _lastLogIndex
    VoteForLazyCandidate {..} -> castLazyVote _newTerm _lazyCandidate _lastLogIndex
    BecomeCandidate {..} -> do
               setRole _newRole
               setTerm _newTerm
               setVotedFor (Just _myNodeId)
               selfYesVote <- return $ createRequestVoteResponse _myNodeId _myNodeId _newTerm _lastLogIndex True
               JT.cYesVotes .= Set.singleton selfYesVote
               JT.cPotentialVotes.= _potentialVotes
               enqueueRequest $ Sender.UpdateState $
                 [ Sender.Update Sender.nodeRole _newRole
                 , Sender.Update Sender.currentTerm _newTerm
                 , Sender.Update Sender.yesVotes (Set.singleton selfYesVote)
                 ]
               enqueueRequest $ Sender.BroadcastRV
               resetElectionTimer

castLazyVote :: Term -> NodeId -> LogIndex -> JT.Raft ()
castLazyVote lazyTerm' lazyCandidate' lazyLastLogIndex' = do
  setTerm lazyTerm'
  setVotedFor (Just lazyCandidate')
  JT.lazyVote .= Nothing
  JT.ignoreLeader .= False
  setCurrentLeader Nothing
  enqueueRequest $ Sender.UpdateState $
    [ Sender.Update Sender.nodeRole Follower
    , Sender.Update Sender.currentTerm lazyTerm'
    , Sender.Update Sender.currentLeader Nothing
    ]
  enqueueRequest $ Sender.BroadcastRVR lazyCandidate' lazyLastLogIndex' True
  -- TODO: we need to verify that this is correct. It seems that a RVR (so a vote) is sent every time an election timeout fires.
  -- However, should that be the case? I think so, as you shouldn't vote for multiple people in the same election. Still though...
  resetElectionTimer

-- THREAD: SERVER MAIN. updates state
setVotedFor :: Maybe NodeId -> JT.Raft ()
setVotedFor mvote = do
  void $ JT.rs.JT.writeVotedFor ^$ mvote
  JT.votedFor .= mvote

createRequestVoteResponse :: NodeId -> NodeId -> Term -> LogIndex -> Bool -> RequestVoteResponse
createRequestVoteResponse me' target' term' logIndex' vote =
  RequestVoteResponse term' logIndex' me' vote target' NewMsg
