{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Consensus.Handle.ElectionTimeout
    (handle)
    where

import Control.Lens
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import Data.Foldable (traverse_)
import qualified Data.Set as Set

import Juno.Consensus.Handle.Types
import Juno.Runtime.Sender (createRequestVoteResponse,sendRPC)
import Juno.Runtime.Timer (resetElectionTimer, hasElectionTimerLeaderFired)
import Juno.Util.Combinator ((^$))
import Juno.Util.Util
import Juno.Types.Log hiding (logEntries)

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
      _lazyTerm :: Term
    , _lazyCandidate :: NodeId
    , _lazyResponse :: RequestVoteResponse
    } |
    AbdicateAndLazyVote {
      _lazyTerm :: Term
    , _lazyCandidate :: NodeId
    , _lazyResponse :: RequestVoteResponse
    } |
    BecomeCandidate {
      _newTerm :: Term
    , _newRole :: Role
    , _myNodeId :: NodeId -- just to be explicit, obviously it's us
    , _selfYesVote :: RequestVoteResponse
    , _potentialVotes :: Set.Set NodeId
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
        me <- view nodeId
        lazyResp <- createRequestVoteResponse lazyTerm lastLogIndex' me lazyCandidate True
        return $ VoteForLazyCandidate lazyTerm lazyCandidate lazyResp
      Nothing -> becomeCandidate
  else if r == Leader && leaderWithoutFollowers'
       then do
            lv <- view lazyVote
            case lv of
              Just (lazyTerm, lazyCandidate, lastLogIndex') -> do
                me <- view nodeId
                lazyResp <- createRequestVoteResponse lazyTerm lastLogIndex' me lazyCandidate True
                return $ AbdicateAndLazyVote lazyTerm lazyCandidate lazyResp
              Nothing -> becomeCandidate
       else return AlreadyLeader

-- THREAD: SERVER MAIN. updates state
becomeCandidate :: (MonadReader ElectionTimeoutEnv m, MonadWriter [String] m) => m ElectionTimeoutOut
becomeCandidate = do
  tell ["becoming candidate"]
  newTerm <- (+1) <$> view term
  me <- view nodeId
  es <- view logEntries
  selfVote <- createRequestVoteResponse newTerm (maxIndex' es) me me True
  provenance <- selfVoteProvenance selfVote
  potentials <- view otherNodes
  return $ BecomeCandidate newTerm Candidate me
             (selfVote {_rvrProvenance = provenance}) potentials

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
    AbdicateAndLazyVote {..} -> setRole Follower >> castLazyVote _lazyTerm _lazyCandidate _lazyResponse
    VoteForLazyCandidate {..} -> castLazyVote _lazyTerm _lazyCandidate _lazyResponse
    BecomeCandidate {..} -> do
               setRole _newRole
               setTerm _newTerm
               setVotedFor (Just _myNodeId)
               JT.cYesVotes .= Set.singleton _selfYesVote
               JT.cPotentialVotes.= _potentialVotes
               resetElectionTimer
               sendAllRequestVotes

castLazyVote :: Term -> NodeId -> RequestVoteResponse -> JT.Raft ()
castLazyVote lazyTerm' lazyCandidate' lazyResponse' = do
  setTerm lazyTerm'
  setVotedFor (Just lazyCandidate')
  JT.lazyVote .= Nothing
  JT.ignoreLeader .= False
  setCurrentLeader Nothing
  sendRPC lazyCandidate' (RVR' lazyResponse')
  -- TODO: we need to verify that this is correct. It seems that a RVR (so a vote) is sent every time an election timeout fires.
  -- However, should that be the case? I think so, as you shouldn't vote for multiple people in the same election. Still though...
  resetElectionTimer

-- THREAD: SERVER MAIN. updates state
setVotedFor :: Maybe NodeId -> JT.Raft ()
setVotedFor mvote = do
  void $ JT.rs.JT.writeVotedFor ^$ mvote
  JT.votedFor .= mvote


-- uses state, but does not update
sendAllRequestVotes :: JT.Raft ()
sendAllRequestVotes = traverse_ sendRequestVote =<< use JT.cPotentialVotes


-- uses state, but does not update
sendRequestVote :: NodeId -> JT.Raft ()
sendRequestVote target = do
  ct <- use JT.term
  nid <- JT.viewConfig JT.nodeId
  ls <- getLogState
  debug $ "sendRequestVote: " ++ show ct
  sendRPC target $ RV' $ RequestVote ct nid (maxIndex' ls) (lastLogTerm' ls) NewMsg
