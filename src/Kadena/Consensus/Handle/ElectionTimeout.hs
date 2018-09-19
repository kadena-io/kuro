{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Kadena.Consensus.Handle.ElectionTimeout
    (handle)
    where

import Control.Exception (Exception)
import Control.Lens
import Control.Monad.Catch (MonadThrow, throwM)
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer

import Data.Set (Set)
import qualified Data.Set as Set
import Data.String (IsString)
import Debug.Trace

import Kadena.Config.ClusterMembership
import qualified Kadena.Config.TMVar as TMV
import Kadena.Types
import qualified Kadena.Types.Sender as Sender (ServiceRequest(..))
import qualified Kadena.Types.Log as Log
import Kadena.Consensus.Util

import qualified Kadena.Types as KD

data ElectionTimeoutEnv = ElectionTimeoutEnv {
      _nodeRole :: Role
    , _term :: Term
    , _lazyVote :: Maybe LazyVote
    , _nodeId :: NodeId
    , _eteClusterMembers :: ClusterMembership
    , _leaderWithoutFollowers :: Bool
    , _myPrivateKey :: PrivateKey
    , _myPublicKey :: PublicKey
    , _eteEnableDiagnostics :: Bool
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
    , _potentialVotes :: Set.Set NodeId
    , _yesVotes :: Set RequestVoteResponse
    }

handleElectionTimeout :: (MonadReader ElectionTimeoutEnv m, MonadWriter [String] m, MonadThrow m)
                      => String -> m ElectionTimeoutOut
handleElectionTimeout s = do
  diagnostics <- view eteEnableDiagnostics
  throwDiagnostics diagnostics "election timeout triggered"
  tell ["election timeout: " ++ s]
  r <- view nodeRole
  leaderWithoutFollowers' <- view leaderWithoutFollowers
  if r /= Leader
  then do
    lv <- view lazyVote
    case lv of
      Just LazyVote{..} ->
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


-- MLN: TODO - find the right home for this
throwDiagnostics :: MonadThrow m => Bool -> String -> m ()
throwDiagnostics diagnostics str = do
  if diagnostics
    then throwM $ DiagnosticException str
    else return ()

-- MLN: TODO -- find the right home for this
newtype DiagnosticException = DiagnosticException String
  deriving (Eq,Show,Ord,IsString)
instance Exception DiagnosticException
  

-- THREAD: SERVER MAIN. updates state
becomeCandidate :: (MonadReader ElectionTimeoutEnv m, MonadWriter [String] m) => m ElectionTimeoutOut
becomeCandidate = do
  tell ["becoming candidate"]
  newTerm <- (+1) <$> view term
  me <- view nodeId
  selfVote <- return $ createRequestVoteResponse me me newTerm True
  provenance <- selfVoteProvenance selfVote
  members <- view eteClusterMembers
  let potentials = otherNodes members
  return $ BecomeCandidate
    { _newTerm = newTerm
    , _newRole = Candidate
    , _myNodeId = me
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
  (out,l) <- runReaderT (runWriterT (handleElectionTimeout msg)) $
             ElectionTimeoutEnv
             (_csNodeRole s)
             (_csTerm s)
             (_csLazyVote s)
             (TMV._nodeId c)
             (TMV._clusterMembers c)
             leaderWithoutFollowers'
             (TMV._myPrivateKey c)
             (TMV._myPublicKey c)
             (TMV._enableDiagnostics c)
  mapM_ debug l
  case out of
    AlreadyLeader -> return ()
    -- this is for handling the leader w/o followers case only
    AbdicateAndLazyVote {..} -> castLazyVote _newTerm _lazyCandidate
    VoteForLazyCandidate {..} -> castLazyVote _newTerm _lazyCandidate
    BecomeCandidate {..} -> do
      setRole _newRole
      setTerm _newTerm
      setVotedFor (Just _myNodeId)
      csYesVotes .= _yesVotes
      csPotentialVotes.= _potentialVotes
      (sigForRV, rv) <- createRequestVote _newTerm _myNodeId (TMV._myPublicKey c) (TMV._myPrivateKey c)
      csInvalidCandidateResults .= Just (InvalidCandidateResults sigForRV Set.empty)
      enqueueRequest $ Sender.BroadcastRV rv
      view KD.informEvidenceServiceOfElection >>= liftIO
      trace "handle in electionTimeout.hs, case BecomeCandidate -- calling resetElectionTimer" $
        resetElectionTimer

castLazyVote :: Term -> NodeId -> KD.Consensus ()
castLazyVote lazyTerm' lazyCandidate' = do
  setTerm lazyTerm'
  setVotedFor (Just lazyCandidate')
  csLazyVote .= Nothing
  csIgnoreLeader .= False
  setCurrentLeader Nothing
  enqueueRequest $ Sender.BroadcastRVR lazyCandidate' Nothing True
  -- TODO: we need to verify that this is correct. It seems that a RVR (so a vote) is sent every time an election timeout fires.
  -- However, should that be the case? I think so, as you shouldn't vote for multiple people in the same election. Still though...
  resetElectionTimer

-- THREAD: SERVER MAIN. updates state
setVotedFor :: Maybe NodeId -> KD.Consensus ()
setVotedFor mvote = csVotedFor .= mvote

createRequestVoteResponse :: NodeId -> NodeId -> Term -> Bool -> RequestVoteResponse
createRequestVoteResponse me' target' term' vote =
  RequestVoteResponse term' Nothing me' vote target' NewMsg

createRequestVote :: Term -> NodeId -> PublicKey -> PrivateKey -> KD.Consensus (Signature, RequestVote)
createRequestVote curTerm' nodeId' myPublicKey' myPrivateKey' = do
  mv <- queryLogs $ Set.fromList [Log.GetMaxIndex, Log.GetLastLogTerm]
  lastLogIndex' <- return $ Log.hasQueryResult Log.MaxIndex mv
  lastLogTerm' <- return $ Log.hasQueryResult Log.LastLogTerm mv
  rv <- return $ RequestVote curTerm' nodeId' lastLogIndex' lastLogTerm' NewMsg
  (SignedRPC dig bdy) <- return $ toWire nodeId' myPublicKey' myPrivateKey' rv
  return (dig ^. KD.digSig, rv { _rvProvenance = ReceivedMsg dig bdy Nothing})
