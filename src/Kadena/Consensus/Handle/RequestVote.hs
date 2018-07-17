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

import qualified Kadena.Config.TMVar as TMV
import qualified Kadena.Sender.Service as Sender
import qualified Kadena.Types.Log as Log
import qualified Kadena.Types as KD

import Kadena.Types
import Kadena.Consensus.Util

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

data RequestVoteOut =
  NoAction |
  UpdateLazyVote { _updateLazyVote :: !LazyVote } |
  UpdateLazyVoteAndVote
    { _updateLazyVote :: !LazyVote
    , _targetNode :: !NodeId
    , _lastLogIndex :: !(Maybe HeardFromLeader)
    , _vote :: Bool } |
  ReplyToRPCSender
    { _targetNode :: !NodeId
    , _lastLogIndex :: !(Maybe HeardFromLeader)
    , _vote :: Bool }

handleRequestVote :: (MonadWriter [String] m, MonadReader RequestVoteEnv m)
                  => RequestVote -> NodeId -> m RequestVoteOut
handleRequestVote rv@RequestVote{..} _myId = do
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
        Nothing -> if currentLeader' == Nothing && term' == startTerm
          then do
            tell ["At cluster launch, so vote immediately and update lazy vote"]
            return $ UpdateLazyVoteAndVote (LazyVote rv (Map.singleton (rv ^. rvCandidateId) rv)) _rvCandidateId hfl False
          else do
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
  nodeId' <- view TMV.nodeId <$> KD.readConfig
  if _csNodeRole s == Leader
  then do
    enqueueRequest Sender.EstablishDominance
    hfl <- return $! mkHeardFromLeader (Just nodeId') (_rvProvenance rv) (Log.hasQueryResult Log.LastLogTerm mv) (Log.hasQueryResult Log.MaxIndex mv)
    enqueueRequest $ Sender.BroadcastRVR (_rvCandidateId rv) hfl False
  else do
    let rve = RequestVoteEnv
          (_csTerm s)
          (_csVotedFor s)
          (_csLazyVote s)
          (_csCurrentLeader s)
          (_csIgnoreLeader s)
          (Log.hasQueryResult Log.MaxIndex mv)
          (Log.hasQueryResult Log.LastLogTerm mv)
    (rvo, l) <- runReaderT (runWriterT (handleRequestVote rv nodeId')) rve
    mapM_ debug l
    case rvo of
      NoAction -> return ()
      UpdateLazyVote stateUpdate -> csLazyVote .= Just stateUpdate
      UpdateLazyVoteAndVote{..} -> do
        csLazyVote .= Just _updateLazyVote
        enqueueRequest $ Sender.BroadcastRVR _targetNode Nothing _vote
      ReplyToRPCSender{..} -> enqueueRequest $ Sender.BroadcastRVR _targetNode Nothing _vote
