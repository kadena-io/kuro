{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Consensus.Handle.RequestVote (
  handle
  ) where

import Control.Lens hiding (Index)
import Control.Monad.Reader
import Control.Monad.Writer.Strict
import Control.Monad.State (get)

import qualified Data.Set as Set
import qualified Data.Map.Strict as Map

import Kadena.Util.Util (debug, enqueueRequest, queryLogs)
import qualified Kadena.Service.Sender as Sender
import qualified Kadena.Service.Log as Log
import qualified Kadena.Types as KD

import Kadena.Consensus.Handle.Types

data RequestVoteEnv = RequestVoteEnv {
-- Old Constructors
    _term             :: Term
  , _votedFor         :: Maybe NodeId
  , _lazyVote         :: Maybe LazyVote
  , _currentLeader    :: Maybe NodeId
  , _ignoreLeader     :: Bool
  , _lastLogIndexIn   :: LogIndex
  , _lastTerm         :: Term
  }
makeLenses ''RequestVoteEnv

data RequestVoteOut = NoAction
                    | UpdateLazyVote { _updateLazyVote :: !LazyVote}
                    | ReplyToRPCSender { _targetNode :: !NodeId
                                       , _lastLogIndex :: !(Maybe HeardFromLeader)
                                       , _vote :: Bool }

handleRequestVote :: (MonadWriter [String] m, MonadReader RequestVoteEnv m) => RequestVote -> m RequestVoteOut
handleRequestVote rv@RequestVote{..} = do
  tell ["got a requestVote RPC for " ++ show _rvTerm]
  votedFor' <- view votedFor
  term' <- view term
  currentLeader' <- view currentLeader
  ignoreLeader' <- view ignoreLeader
  lli <- view lastLogIndexIn
  llt <- view lastTerm
  let hfl = mkHeardFromLeader currentLeader' _rvProvenance llt lli
  case votedFor' of
    _      | ignoreLeader' && currentLeader' == Just _rvCandidateId -> return NoAction
      -- don't respond to a candidate if they were leader and a client
      -- asked us to ignore them

    _      | _rvTerm < term' -> do
      -- this is an old candidate
      tell ["this is for an old term"]
      return $ ReplyToRPCSender _rvCandidateId hfl False

    Just c | c == _rvCandidateId && _rvTerm == term' -> do
      -- already voted for this candidate in this term
      tell ["already voted for this candidate"]
      return $ ReplyToRPCSender _rvCandidateId Nothing True

    Just _ | _rvTerm == term' -> do
      -- already voted for a different candidate in this term
      tell ["already voted for a different candidate"]
      return $ ReplyToRPCSender _rvCandidateId Nothing False

    _ | _rvLastLogIndex < lli -> do
      tell ["Candidate has an out of date log, so vote no immediately"]
      return $ ReplyToRPCSender _rvCandidateId hfl False

    _ | (_rvLastLogTerm, _rvLastLogIndex) >= (llt, lli) -> do
      lv <- view lazyVote
      case lv of
        Nothing -> do
          tell ["haven't voted, (lazily) voting for this candidate"]
          return $ UpdateLazyVote $ LazyVote rv (Map.singleton (rv ^. rvCandidateId) rv)
        Just lv'
          | (lv' ^. lvVoteFor.rvTerm) >= _rvTerm -> do
              tell ["would vote lazily, but already voted lazily for candidate in same or higher term"]
              return $ UpdateLazyVote lv'
                -- if we already have an RV for this nodeId then compare the terms, biased towards always keeping the newer one
                { _lvAllReceived = Map.insertWith (\old new -> if (old ^. rvTerm) > (new ^. rvTerm) then old else new) (rv ^. rvCandidateId) rv (lv' ^. lvAllReceived) }
          | otherwise -> do
              tell ["replacing lazy vote"]
              return $ UpdateLazyVote $ LazyVote
                { _lvVoteFor = rv
                , _lvAllReceived = Map.insert (rv ^. rvCandidateId) rv (lv' ^. lvAllReceived) }
    _ -> do
      tell ["haven't voted, but my log is better than this candidate's"]
      return $ ReplyToRPCSender _rvCandidateId hfl False

mkHeardFromLeader :: Maybe NodeId -> Provenance -> Term -> LogIndex -> Maybe HeardFromLeader
mkHeardFromLeader _ NewMsg _ _ = error $ "Invariant Error: RV that is a new message encountered in mkHeardFromLeader"
mkHeardFromLeader Nothing _ _ _= Nothing
mkHeardFromLeader (Just leader') ReceivedMsg{..} term' lli' = Just $ HeardFromLeader
  { _hflLeaderId = leader'
  , _hflYourRvSig = _pDig ^. KD.digSig
  , _hflLastLogIndex = lli'
  , _hflLastLogTerm = term'
  }

handle :: RequestVote -> KD.Consensus ()
handle rv = do
  s <- get
  mv <- queryLogs $ Set.fromList [Log.GetMaxIndex, Log.GetLastLogTerm]
  let rve = RequestVoteEnv
              (KD._term s)
              (KD._votedFor s)
              (KD._lazyVote s)
              (KD._currentLeader s)
              (KD._ignoreLeader s)
              (Log.hasQueryResult Log.MaxIndex mv)
              (Log.hasQueryResult Log.LastLogTerm mv)
  (rvo, l) <- runReaderT (runWriterT (handleRequestVote rv)) rve
  mapM_ debug l
  case rvo of
    NoAction -> return ()
    UpdateLazyVote stateUpdate -> KD.lazyVote .= Just stateUpdate
    ReplyToRPCSender{..} -> enqueueRequest $ Sender.BroadcastRVR _targetNode Nothing _vote
