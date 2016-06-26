{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Consensus.Handle.RequestVote (
  handle
  ) where

import Control.Lens hiding (Index)
import Control.Monad.Reader
import Control.Monad.Writer.Strict
import Control.Monad.State (get)

import Juno.Util.Util (debug)
import Juno.Runtime.Sender (sendRPC,createRequestVoteResponse)
import Juno.Types.Log

import Juno.Consensus.Handle.Types

import qualified Juno.Types as JT

data RequestVoteEnv = RequestVoteEnv {
-- Old Constructors
    _term             :: Term
  , _votedFor         :: Maybe NodeId
  , _lazyVote         :: Maybe (Term, NodeId, LogIndex)
  , _currentLeader    :: Maybe NodeId
  , _ignoreLeader     :: Bool
  , _logEntries       :: Log LogEntry
-- New Constructors
  , _myNodeId :: NodeId
  }
makeLenses ''RequestVoteEnv

data RequestVoteOut = NoAction
                    | UpdateLazyVote { _stateCastLazyVote :: (Term, NodeId, LogIndex) }
                    | VoteForRPCSender { _returnMsgs :: (NodeId, RequestVoteResponse) }

handleRequestVote :: (MonadWriter [String] m, MonadReader RequestVoteEnv m) => RequestVote -> m RequestVoteOut
handleRequestVote RequestVote{..} = do
  tell ["got a requestVote RPC for " ++ show _rvTerm]
  votedFor' <- view votedFor
  logEntries' <- view logEntries
  term' <- view term
  currentLeader' <- view currentLeader
  ignoreLeader' <- view ignoreLeader
  let lli = maxIndex logEntries'
      llt = lastLogTerm logEntries'
  case votedFor' of
    _      | ignoreLeader' && currentLeader' == Just _rvCandidateId -> return NoAction
      -- don't respond to a candidate if they were leader and a client
      -- asked us to ignore them

    _      | _rvTerm < term' -> do
      -- this is an old candidate
      tell ["this is for an old term"]
      m <- createRequestVoteResponse' _rvCandidateId lli False
      return $ VoteForRPCSender m

    Just c | c == _rvCandidateId && _rvTerm == term' -> do
      -- already voted for this candidate in this term
      tell ["already voted for this candidate"]
      m <- createRequestVoteResponse' _rvCandidateId lli True
      return $ VoteForRPCSender m

    Just _ | _rvTerm == term' -> do
      -- already voted for a different candidate in this term
      tell ["already voted for a different candidate"]
      m <- createRequestVoteResponse' _rvCandidateId lli False
      return $ VoteForRPCSender m

    _ | _rvLastLogIndex < lli -> do
      tell ["Candidate has an out of date log, so vote no immediately"]
      m <- createRequestVoteResponse' _rvCandidateId lli False
      return $ VoteForRPCSender m

    _ | (_rvLastLogTerm, _rvLastLogIndex) >= (llt, lli) -> do
      lv <- view lazyVote
      case lv of
        Just (t, _, _) | t >= _rvTerm -> do
          tell ["would vote lazily, but already voted lazily for candidate in same or higher term"]
          return NoAction
        Just _ -> do
          tell ["replacing lazy vote"]
          return $ UpdateLazyVote (_rvTerm, _rvCandidateId, lli)
        Nothing -> do
          tell ["haven't voted, (lazily) voting for this candidate"]
          return $ UpdateLazyVote (_rvTerm, _rvCandidateId, lli)
    _ -> do
      tell ["haven't voted, but my log is better than this candidate's"]
      m <- createRequestVoteResponse' _rvCandidateId lli False
      return $ VoteForRPCSender m

createRequestVoteResponse' :: (MonadWriter [String] m, MonadReader RequestVoteEnv m) => NodeId -> LogIndex -> Bool -> m (NodeId, RequestVoteResponse)
createRequestVoteResponse' target lastLogIndex' vote = do
  term' <- view term
  myNodeId' <- view myNodeId
  (target,) <$> createRequestVoteResponse term' lastLogIndex' myNodeId' target vote


handle :: RequestVote -> JT.Raft ()
handle rv = do
  r <- JT.readConfig
  s <- get
  let rve = RequestVoteEnv
              (JT._term s)
              (JT._votedFor s)
              (JT._lazyVote s)
              (JT._currentLeader s)
              (JT._ignoreLeader s)
              (JT._logEntries s)
              (JT._nodeId r)
  (rvo, l) <- runReaderT (runWriterT (handleRequestVote rv)) rve
  mapM_ debug l
  case rvo of
    NoAction -> return ()
    UpdateLazyVote stateUpdate -> JT.lazyVote .= Just stateUpdate
    VoteForRPCSender (targetNode, rpc) -> sendRPC targetNode $ JT.RVR' rpc
