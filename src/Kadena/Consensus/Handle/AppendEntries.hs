{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Consensus.Handle.AppendEntries
  ( createAppendEntriesResponse
  , clearLazyVoteAndInformCandidates
  , handle
  ) where

import Control.Lens hiding (Index)
import Control.Monad.Reader
import Control.Monad.State (get)
import Control.Monad.Writer.Strict

import qualified Data.BloomFilter as Bloom
import qualified Data.Map.Strict as Map
import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Maybe (fromMaybe)
import Data.Thyme.Clock

import qualified Kadena.Config.ClusterMembership as CM
import Kadena.Config.TMVar
import Kadena.Command
import Kadena.Types
import Kadena.Sender.Service (createAppendEntriesResponse')
import Kadena.Consensus.Util
import qualified Kadena.Types as KD
import qualified Kadena.Sender.Service as Sender
import qualified Kadena.Log as Log
import qualified Kadena.Types.Log as Log

data AppendEntriesEnv = AppendEntriesEnv {
-- Old Constructors
    _term              :: Term
  , _currentLeader     :: Maybe NodeId
  , _ignoreLeader      :: Bool
  , _logEntryAtPrevIdx :: Maybe LogEntry
-- New Constructors
  , _quorumSize        :: Int  -- not used in voting during config change
  , _aeeGlobalConfig   :: GlobalConfigTMVar
  }
makeLenses ''AppendEntriesEnv

data AppendEntriesOut = AppendEntriesOut {
      _newLeaderAction :: CheckForNewLeaderOut
    , _result :: AppendEntriesResult
}

data CheckForNewLeaderOut =
  LeaderUnchanged |
  NewLeaderConfirmed {
      _stateRsUpdateTerm  :: Term
    , _stateIgnoreLeader  :: Bool
    , _stateCurrentLeader :: NodeId
    , _stateRole          :: Role
    }

data AppendEntriesResult =
    Ignore |
    SendUnconvincedResponse {
      _responseLeaderId :: NodeId } |
    ValidLeaderAndTerm {
        _responseLeaderId :: NodeId
      , _validReponse :: ValidResponse }

-- TODO: we need a Noop version as well
data ValidResponse =
    SendFailureResponse |
    Commit
      { _newRequestKeys :: HashSet RequestKey
      , _newEntries :: ReplicateLogEntries } |
    DoNothing

-- THREAD: SERVER MAIN. updates state
handleAppendEntries :: (MonadWriter [String] m, MonadReader AppendEntriesEnv m, MonadIO m) =>
                        AppendEntries -> NodeId -> m AppendEntriesOut
handleAppendEntries ae@AppendEntries{..} myId = do
  tell ["received appendEntries: " ++ show _prevLogIndex ]
  nlo <- checkForNewLeader ae
  (currentLeader',ignoreLeader',currentTerm' ) :: (Maybe NodeId,Bool,Term) <-
                case nlo of
                  LeaderUnchanged -> (,,) <$> view currentLeader <*> view ignoreLeader <*> view term
                  NewLeaderConfirmed{..} ->
                    return (Just _stateCurrentLeader,_stateIgnoreLeader,_stateRsUpdateTerm)
  case currentLeader' of
    Just leader' | not ignoreLeader' && leader' == _leaderId && _aeTerm == currentTerm' -> do
      plmatch <- prevLogEntryMatches _prevLogIndex _prevLogTerm
      if not plmatch
        then return $ AppendEntriesOut nlo $ ValidLeaderAndTerm _leaderId SendFailureResponse
        else AppendEntriesOut nlo . ValidLeaderAndTerm _leaderId
                <$> appendLogEntries myId _prevLogIndex _aeEntries
          {-
          if (not (Seq.null _aeEntries))
            -- only broadcast when there are new entries
            -- this has the downside that recovering nodes won't update
            -- their commit index until new entries come along
            -- not sure if this is okay or not
            -- committed entries by definition have already been externalized
            -- so if a particular node missed it, there were already 2f+1 nodes
            -- that didn't
            then sendAllAppendEntriesResponse
            else sendAppendEntriesResponse _leaderId True True
          -}
    _ | not ignoreLeader' && _aeTerm >= currentTerm' -> do -- see TODO about setTerm
      let str' = "sending unconvinced response for AE received from "
           ++ show (KD.unAlias $ _digNodeId $ _pDig $ _aeProvenance)
           ++ " for " ++ show (_aeTerm, _prevLogIndex)
           ++ " with " ++ show (Log.lesCnt _aeEntries)
           ++ " entries; my term is " ++ show currentTerm'
      tell [ str']
      return $ AppendEntriesOut nlo $ SendUnconvincedResponse _leaderId
    _ -> return $ AppendEntriesOut nlo Ignore

checkForNewLeader :: (MonadWriter [String] m, MonadReader AppendEntriesEnv m, MonadIO m) =>
                      AppendEntries -> m CheckForNewLeaderOut
checkForNewLeader AppendEntries{..} = do
  term' <- view term
  currentLeader' <- view currentLeader
  if (_aeTerm == term' && currentLeader' == Just _leaderId)
    || _aeTerm < term'
    || Set.size _aeQuorumVotes == 0
  then return LeaderUnchanged
  else do
     tell ["New potential leader identified: " ++ show _leaderId]
     votesValid <- confirmElection _leaderId _aeTerm _aeQuorumVotes
     tell ["New leader votes are valid: " ++ show votesValid]
     if votesValid
     then return $ NewLeaderConfirmed
          _aeTerm
          False
          _leaderId
          Follower
     else return LeaderUnchanged

confirmElection :: (MonadWriter [String] m, MonadReader AppendEntriesEnv m, MonadIO m) =>
                    NodeId -> Term -> Set RequestVoteResponse -> m Bool
confirmElection leader' term' votes = do
  tell ["confirming election of a new leader"]
  globalConfigVar <- view aeeGlobalConfig
  config <- liftIO $ readCurrentConfig globalConfigVar
  let newNodes = CM.transitionalNodes (_clusterMembers config)
  quorumOk <- if not (Set.null newNodes)
                then return $ cfgChangeConfirmElection config votes
                else do
                  quorumSize' <- view quorumSize
                  return ((Set.size votes) >= quorumSize')
  if quorumOk
    then return $ all (validateVote leader' term') votes
    else return False

-- Confirm election during the config change process.  There must be consensus with respect to both
-- the exisiting set of nodes and the new configuration's set of nodes
cfgChangeConfirmElection :: Config -> Set RequestVoteResponse -> Bool
cfgChangeConfirmElection config votes =
  let members = config^.clusterMembers
      voteIds = Set.map _rvrNodeId votes
  in CM.checkQuorum members voteIds

validateVote :: NodeId -> Term -> RequestVoteResponse -> Bool
validateVote leader' term' RequestVoteResponse{..} = _rvrCandidateId == leader' && _rvrTerm == term'

prevLogEntryMatches :: MonadReader AppendEntriesEnv m => LogIndex -> Term -> m Bool
prevLogEntryMatches pli plt = do
  mOurReplicatedLogEntry <- view logEntryAtPrevIdx
  case mOurReplicatedLogEntry of
    -- if we don't have the entry, only return true if pli is startIndex
    Nothing    -> return (pli == startIndex)
    -- if we do have the entry, return true if the terms match
    Just LogEntry{..} -> return (_leTerm == plt)

appendLogEntries :: (MonadWriter [String] m, MonadReader AppendEntriesEnv m)
                 => NodeId -> LogIndex -> LogEntries -> m ValidResponse
appendLogEntries _myId pli newEs
  | Log.lesNull newEs = return DoNothing
  | otherwise =
    case Log.toReplicateLogEntries pli newEs of
      Left err -> do
        tell ["Failure to Append Logs: " ++ err]
        return SendFailureResponse
      Right rle -> do
        replay <- return $ HashSet.fromList $ fmap (toRequestKey . _leCommand) (Map.elems (newEs ^. Log.logEntries))
        tell ["replicated LogEntry(s): " ++ show (_rleMinLogIdx rle) ++ " through " ++ show (_rleMaxLogIdx rle)]
        return $ Commit replay rle

applyNewLeader :: CheckForNewLeaderOut -> KD.Consensus ()
applyNewLeader LeaderUnchanged = return ()
applyNewLeader NewLeaderConfirmed{..} = do
  setTerm _stateRsUpdateTerm
  csIgnoreLeader .= _stateIgnoreLeader
  setCurrentLeader $ Just _stateCurrentLeader
  view KD.informEvidenceServiceOfElection >>= liftIO
  setRole _stateRole

logHashChange :: Hash -> KD.Consensus ()
logHashChange (Hash mLastHash) =
  logMetric $ KD.MetricHash mLastHash

{-
handleCC :: ClusterChangeMsg -> KD.Consensus ()
handleCC (ClusterChangeMsg _ ae) = do
  error "handleCC is actually called"
  handle ae
-}

handle :: AppendEntries -> KD.Consensus ()
handle ae = do
  start' <- now
  s <- get
  vc <- viewConfig clusterMembers
  let quorumSize' = CM.minQuorumOthers vc
  myId <- viewConfig nodeId
  mv <- queryLogs $ Set.fromList [Log.GetSomeEntry (_prevLogIndex ae),Log.GetCommitIndex]
  logAtAEsLastLogIdx <- return $ Log.hasQueryResult (Log.SomeEntry $ _prevLogIndex ae) mv
  config <- view cfg
  let ape = AppendEntriesEnv
              (_csTerm s)
              (_csCurrentLeader s)
              (_csIgnoreLeader s)
              logAtAEsLastLogIdx
              quorumSize'
              config
  (AppendEntriesOut{..}, l) <- runReaderT (runWriterT (handleAppendEntries ae myId)) ape
  mapM_ debug l
  applyNewLeader _newLeaderAction
  case _result of
    Ignore -> do
      let str = "appendEntries - Ignoring AE from: "
                ++ show (KD.unAlias $ _digNodeId $ _pDig $ _aeProvenance ae )
                ++ " for " ++ show (_prevLogIndex $ ae)
                ++ " with " ++ show (Log.lesCnt $ _aeEntries ae) ++ " entries."
      debug str
      return ()
    SendUnconvincedResponse{..} -> enqueueRequest $ Sender.SingleAER _responseLeaderId False False
    ValidLeaderAndTerm{..} -> do
      case _validReponse of
        SendFailureResponse -> enqueueRequest $ Sender.SingleAER _responseLeaderId False True
        (Commit rks rle) -> do
-- MASSIVE TODO: analyze if this is the best thing to do. Another option would be to drop entries but then nodes could get out of sync, or should we have
-- CryptoWorker also do this and take it out of consensus completely
--          alreadyExist <- queryHistoryForPriorApplication rks
--          if HashSet.null alreadyExist
--          then do
            end' <- now
            updateLogs $ Log.ULReplicate $ updateRleLats start' end' rle
            newMv <- queryLogs $ Set.singleton Log.GetLastLogHash
            newLastLogHash' <- return $! Log.hasQueryResult Log.LastLogHash newMv
            logHashChange newLastLogHash'
            sendHistoryNewKeys rks
            csCmdBloomFilter %= Bloom.insertList (HashSet.toList rks)
--          else do
--            enqueueRequest $ Sender.SingleAER _responseLeaderId False True
--            enqueueRequest Sender.BroadcastAER -- NB: this can only happen after `updateLogs` is complete, the tracer query makes sure of this
--            debug $ "Failure! Leader sent us entries with logEntries that have already been committed"
        DoNothing -> enqueueRequest Sender.BroadcastAER
      clearLazyVoteAndInformCandidates
      -- This NEEDS to be last, otherwise we can have an election fire when we are are transmitting proof/accessing the logs
      -- It's rare but under load and given enough time, this will happen.
      when (_csNodeRole s /= Leader) resetElectionTimer
      -- This `when` fixes a funky bug. If the leader receives an AE from itself it will reset its election timer (which can kill the leader).
      -- Ignoring this is safe because if we have an out of touch leader they will step down after 2x maxElectionTimeouts if it receives no valid AER

createAppendEntriesResponse :: Bool -> Bool -> LogIndex -> Hash -> KD.Consensus AppendEntriesResponse
createAppendEntriesResponse success convinced maxIndex' lastLogHash' = do
  ct <- use csTerm
  myNodeId' <- KD.viewConfig nodeId
  case createAppendEntriesResponse' success convinced ct myNodeId' maxIndex' lastLogHash' of
    AER' aer -> return aer
    _ -> error "deep invariant error: crtl-f for createAppendEntriesResponse"

clearLazyVoteAndInformCandidates :: KD.Consensus ()
clearLazyVoteAndInformCandidates = do
  csInvalidCandidateResults .= Nothing -- setting this to nothing is likely overkill
  lazyVote' <- use csLazyVote
  case lazyVote' of
    Nothing -> return ()
    Just lv -> do
      newMv <- queryLogs $ Set.fromList $ [Log.GetLastLogTerm, Log.GetLastLogIndex]
      term' <- return $! Log.hasQueryResult Log.LastLogTerm newMv
      logIndex' <- return $! Log.hasQueryResult Log.LastLogIndex newMv
      leaderId' <- fromMaybe (error "Invariant Error in clearLazyVote: could not get leaderId") <$> use csCurrentLeader
      mapM_ (issueHflRVR leaderId' term' logIndex') (Map.elems (lv ^. lvAllReceived))
      csLazyVote .= Nothing

issueHflRVR :: NodeId -> Term -> LogIndex -> RequestVote -> KD.Consensus ()
issueHflRVR leaderId' term' logIndex' rv@RequestVote{..} = do
  let hfl = Just $! HeardFromLeader
            { _hflLeaderId = leaderId'
            , _hflYourRvSig = getRvSigOrInvariantError
            , _hflLastLogIndex = logIndex'
            , _hflLastLogTerm = term'
            }
      getRvSigOrInvariantError = case _rvProvenance of
          NewMsg -> error $ "Invariant error in issueHflRVR: could not get sig from new msg" ++ show rv
          (ReceivedMsg dig _ _) -> dig ^. KD.digSig
  enqueueRequest $ Sender.BroadcastRVR _rvCandidateId hfl False

updateRleLats :: UTCTime -> UTCTime -> ReplicateLogEntries -> ReplicateLogEntries
updateRleLats hitCon finCon r@ReplicateLogEntries{..} = r { _rleEntries = updatedLats }
  where
    updatedLats :: LogEntries
    updatedLats = LogEntries $! updateLat <$> _logEntries _rleEntries
    updateLat :: LogEntry -> LogEntry
    updateLat le@LogEntry{..} = case _leCmdLatMetrics of
      Nothing -> le
      Just lat -> le { _leCmdLatMetrics = Just $ lat { _lmHitConsensus = Just hitCon
                                                     , _lmFinConsensus = Just finCon}
                     }
{-# INLINE updateRleLats #-}
