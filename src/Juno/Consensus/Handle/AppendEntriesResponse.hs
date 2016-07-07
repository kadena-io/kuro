{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Consensus.Handle.AppendEntriesResponse
  (handle
  ,handleAlotOfAers
  ,updateCommitProofMap)
where

import Control.Lens hiding (Index)
import Control.Monad.Reader
import Control.Monad.State (get)
import Control.Monad.Writer.Strict
import Control.Parallel.Strategies

import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Juno.Consensus.Commit (doCommit)
import Juno.Consensus.Handle.Types
import qualified Juno.Service.Sender as Sender
import qualified Juno.Service.Log as Log
import Juno.Runtime.Timer (resetElectionTimerLeader)
import Juno.Util.Util (debug, updateLNextIndex, queryLogs, enqueueRequest)
import qualified Juno.Types as JT

data AEResponseEnv = AEResponseEnv {
-- Old Constructors
    _nodeRole         :: Role
  , _term             :: Term
  , _commitProof      :: Map NodeId AppendEntriesResponse
  }
makeLenses ''AEResponseEnv

data AEResponseOut = AEResponseOut
  { _stateMergeCommitProof :: Map NodeId AppendEntriesResponse
  , _leaderState :: LeaderState }

data LeaderState =
  DoNothing |
  NotLeader |
  StatelessSendAE
    { _sendAENodeId :: NodeId } |
  Unconvinced -- sends AE after
    { _sendAENodeId :: NodeId
    , _deleteConvinced :: NodeId } |
  ConvincedAndUnsuccessful -- sends AE after
    { _sendAENodeId :: NodeId
    , _setLaggingLogIndex :: LogIndex } |
  ConvincedAndSuccessful -- may send AE after
    { _sendAENodeId :: NodeId
    , _incrementNextIndexNode :: NodeId
    , _incrementNextIndexLogIndex :: LogIndex
    , _insertConvinced :: NodeId}


data Convinced = Convinced | NotConvinced
data AESuccess = Success | Failure
data RequestTermStatus = OldRequestTerm | CurrentRequestTerm | NewerRequestTerm

handleAEResponse :: (MonadWriter [String] m, MonadReader AEResponseEnv m) => AppendEntriesResponse -> m AEResponseOut
handleAEResponse aer@AppendEntriesResponse{..} = do
    --tell ["got an appendEntriesResponse RPC"]
    mcp <- updateCommitProofMap aer <$> view commitProof
    role' <- view nodeRole
    currentTerm' <- view term
    if (role' == Leader)
    then
      return $ case (isConvinced, isSuccessful, whereIsTheRequest currentTerm') of
        (NotConvinced, _, OldRequestTerm) -> AEResponseOut mcp $ Unconvinced _aerNodeId _aerNodeId
        (NotConvinced, _, CurrentRequestTerm) -> AEResponseOut mcp $ Unconvinced _aerNodeId _aerNodeId
        (Convinced, Failure, CurrentRequestTerm) -> AEResponseOut mcp $ ConvincedAndUnsuccessful _aerNodeId _aerIndex
        (Convinced, Success, CurrentRequestTerm) -> AEResponseOut mcp $ ConvincedAndSuccessful _aerNodeId _aerNodeId _aerIndex _aerNodeId
        -- The next two case are underspecified currently and they should not occur as
        -- they imply that a follow is ahead of us but the current code sends an AER anyway
        (NotConvinced, _, _) -> AEResponseOut mcp $ StatelessSendAE _aerNodeId
        (_, Failure, _) -> AEResponseOut mcp $ StatelessSendAE _aerNodeId
        -- This is just a fall through case in the current code
        -- do nothing as the follower is convinced and successful but out of date? Shouldn't this trigger a replay AE?
        (Convinced, Success, OldRequestTerm) -> AEResponseOut mcp DoNothing
        -- We are a leader, in a term that hasn't happened yet?
        (_, _, NewerRequestTerm) -> AEResponseOut mcp DoNothing
    else return $ AEResponseOut mcp NotLeader
  where
    isConvinced = if _aerConvinced then Convinced else NotConvinced
    isSuccessful = if _aerSuccess then Success else Failure
    whereIsTheRequest ct | _aerTerm == ct = CurrentRequestTerm
                         | _aerTerm < ct = OldRequestTerm
                         | otherwise = NewerRequestTerm

updateCommitProofMap :: AppendEntriesResponse -> Map NodeId AppendEntriesResponse -> Map NodeId AppendEntriesResponse
updateCommitProofMap aerNew m = Map.alter go nid m
  where
    nid :: NodeId
    nid = _aerNodeId aerNew
    go = \case
      Nothing   -> Just aerNew
      Just aerOld -> if _aerIndex aerNew > _aerIndex aerOld
                     then Just aerNew
                     else Just aerOld

handle :: AppendEntriesResponse -> JT.Raft ()
handle aer = do
  s <- get
  let ape = AEResponseEnv
              (JT._nodeRole s)
              (JT._term s)
              (JT._commitProof s)
  (AEResponseOut{..}, l) <- runReaderT (runWriterT (handleAEResponse aer)) ape
  mapM_ debug l
  JT.commitProof .= _stateMergeCommitProof
  doCommit
  case _leaderState of
    NotLeader -> return ()
    DoNothing -> return ()
    StatelessSendAE{..} -> do
      lNextIndex' <- use JT.lNextIndex >>= return . Map.lookup _sendAENodeId
      enqueueRequest $! Sender.SingleAE _sendAENodeId lNextIndex' True
      resetElectionTimerLeader
    Unconvinced{..} -> do
      JT.lConvinced %= Set.delete _deleteConvinced
      lNextIndex' <- use JT.lNextIndex >>= return . Map.lookup _sendAENodeId
      enqueueRequest $! Sender.SingleAE _sendAENodeId lNextIndex' False
    ConvincedAndSuccessful{..} -> do
      mv <- queryLogs $ Set.fromList [Log.GetLastLogIndex, Log.GetCommitIndex]
      ci <- return $ Log.hasQueryResult Log.CommitIndex mv
      myLatestIndex <- return $ Log.hasQueryResult Log.LastLogIndex mv
      updateLNextIndex ci $ Map.insert _incrementNextIndexNode $ _incrementNextIndexLogIndex + 1
      JT.lConvinced %= Set.insert _insertConvinced
      -- If the commit was a success but we have more, chase the response with an update
      when (myLatestIndex > _incrementNextIndexLogIndex) $ do
        enqueueRequest $! Sender.SingleAE _sendAENodeId (Just $ _incrementNextIndexLogIndex + 1) True
      resetElectionTimerLeader
    ConvincedAndUnsuccessful{..} -> do
      ci <- Log.hasQueryResult Log.CommitIndex <$> (queryLogs $ Set.singleton Log.GetCommitIndex)
      updateLNextIndex ci $ Map.insert _sendAENodeId _setLaggingLogIndex
      enqueueRequest $! Sender.SingleAE _sendAENodeId (Just _setLaggingLogIndex) True
      resetElectionTimerLeader

handleAlotOfAers :: AlotOfAERs -> JT.Raft ()
handleAlotOfAers (AlotOfAERs m) = do
  ks <- KeySet <$> JT.viewConfig JT.publicKeys <*> JT.viewConfig JT.clientPublicKeys
  res <- return ((processSetAer ks <$> Map.elems m) `using` parList rseq)
  aers <- catMaybes <$> mapM (\(a,l) -> mapM_ debug l >> return a) res
  mapM_ handle aers

processSetAer :: KeySet -> Set AppendEntriesResponse -> (Maybe AppendEntriesResponse, [String])
processSetAer ks s = go [] (Set.toDescList s)
  where
    go fails [] = (Nothing, fails)
    go fails (aer:rest)
      | _aerWasVerified aer = (Just aer, fails)
      | otherwise = case aerReVerify ks aer of
                      Left f -> go (f:fails) rest
                      Right () -> (Just $ aer {_aerWasVerified = True}, fails)


-- | Verify if needed on `ReceivedMsg` provenance
aerReVerify :: KeySet -> AppendEntriesResponse -> Either String ()
aerReVerify  _ AppendEntriesResponse{ _aerWasVerified = True } = Right ()
aerReVerify  _ AppendEntriesResponse{ _aerProvenance = NewMsg } = Right ()
aerReVerify ks AppendEntriesResponse{
                  _aerWasVerified = False,
                  _aerProvenance = ReceivedMsg{..}
                } = verifySignedRPC ks $ SignedRPC _pDig _pOrig
