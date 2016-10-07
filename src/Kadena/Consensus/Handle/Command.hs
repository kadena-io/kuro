{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Consensus.Handle.Command
    (handle
    ,handleBatch)
    where

import Control.Lens
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import Control.Parallel.Strategies

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Data.BloomFilter (Bloom)
import qualified Data.BloomFilter as Bloom
import Data.Maybe (isNothing, isJust, fromJust)
import Data.Either (partitionEithers)

import Kadena.Consensus.Handle.Types
import Kadena.Consensus.Util
import qualified Kadena.Types as KD

import qualified Kadena.Sender.Service as Sender
import qualified Kadena.Evidence.Service as Ev

data CommandEnv = CommandEnv {
      _nodeRole :: Role
    , _term :: Term
    , _currentLeader :: Maybe NodeId
    , _nodeId :: NodeId
    , _cmdBloomFilter :: Bloom RequestKey
}
makeLenses ''CommandEnv

data CommandOut =
    UnknownLeader |
    RetransmitToLeader { _leaderId :: NodeId } |
    CommitAndPropagate {
      _newEntry :: NewLogEntries
    , _replayKey :: RequestKey
    } |
    AlreadySeen

newtype BPNewEntries = BPNewEntries { _unBPNewEntries :: [Command]} deriving (Eq, Show)
newtype BPAlreadySeen = BPAlreadySeen { _unBPAlreadySeen :: [Command]} deriving (Eq, Show)

data BatchProcessing = BatchProcessing
  { newEntries :: !BPNewEntries
  , alreadySeen :: !BPAlreadySeen
  } deriving (Show, Eq)

data CommandBatchOut =
  IAmLeader BatchProcessing |
  IAmFollower BatchProcessing |
  IAmCandidate

-- THREAD: SERVER MAIN. updates state
handleCommand :: (MonadReader CommandEnv m,MonadWriter [String] m) => Command -> m CommandOut
handleCommand cmd@Command{..} = do
  tell ["got a command RPC"]
  r <- view nodeRole
  ct <- view term
  mlid <- view currentLeader
  _nid <- view nodeId
  rk <- return $ toRequestKey "handleCommand" cmd
  case (Map.lookup rk replays, r, mlid) of
    (Just (Just _result), _, _) -> do
      -- cmdr <- return $ makeCommandResponse' nid cmd result
      -- return . SendCommandResponse _cmdClientId $ cmdr 1
      -- we have already committed this request, so send the result to the client
      -- NOPE. now we just drop CMDRs
      return AlreadySeen
    (Just Nothing, _, _) ->
      -- we have already seen this request, but have not yet committed it
      -- nothing to do
      return AlreadySeen
    (_, Leader, _) ->
      -- we're the leader, so append this to our log with the current term
      -- and propagate it to replicas
      return $ CommitAndPropagate (NewLogEntries ct (KD.NleEntries [cmd])) rk
    (_, _, Just lid) ->
      -- we're not the leader, but we know who the leader is, so forward this
      -- command (don't sign it ourselves, as it comes from the client)
      return $ RetransmitToLeader lid
    (_, _, Nothing) ->
      -- we're not the leader, and we don't know who the leader is, so can't do
      -- anything
      return UnknownLeader

filterBatch :: Bloom RequestKey -> Commands -> BatchProcessing
filterBatch bfilter (Commands cs) = BatchProcessing (BPNewEntries brandNew) (BPAlreadySeen likelySeen)
  where
    probablyAlreadySaw cmd@Command{..} =
      -- forcing the inside of an either is notoriously hard. in' is trying to at least force the majority of the work
      let in' = Bloom.elem (toRequestKey "filterBatch" cmd) bfilter
          res = if in'
            then Left cmd
            else Right cmd
      in in' `seq` res
    (likelySeen, brandNew) = partitionEithers $! ((probablyAlreadySaw <$> cs) `using` parListN 100 rseq)
{-# INLINE filterBatch #-}

handleCommandBatch :: (MonadReader CommandEnv m,MonadWriter [String] m) => CommandBatch -> m CommandBatchOut
handleCommandBatch CommandBatch{..} = do
  tell ["got a command RPC"]
  r <- view nodeRole
  bloom <- view cmdBloomFilter
  return $! case r of
    Leader -> IAmLeader $ filterBatch bloom _cmdbBatch
    Follower -> IAmFollower $ filterBatch bloom _cmdbBatch
    Candidate -> IAmCandidate

handleSingleCommand :: Command -> KD.Consensus ()
handleSingleCommand cmd = do
  c <- KD.readConfig
  s <- get
  (out,_) <- runReaderT (runWriterT (handleCommand cmd)) $
             CommandEnv (KD._nodeRole s)
                        (KD._term s)
                        (KD._currentLeader s)
                        (KD._replayMap s)
                        (KD._nodeId c)
                        (KD._cmdBloomFilter s)
  case out of
    UnknownLeader -> return () -- TODO: we should probably respond with something like "availability event"
    AlreadySeen -> return () -- TODO: we should probably respond with something like "transaction still pending"
    (RetransmitToLeader lid) -> enqueueRequest $ Sender.ForwardCommandToLeader lid [cmd]
    (CommitAndPropagate newEntry replayKey) -> do
      updateLogs $ ULNew newEntry
      enqueueRequest $ Sender.BroadcastAE Sender.OnlySendIfFollowersAreInSync
      enqueueRequest $ Sender.BroadcastAER
      quorumSize' <- view KD.quorumSize
      es <- view KD.evidenceState >>= liftIO
      when (Sender.willBroadcastAE quorumSize' (es ^. Ev.pesNodeStates) (es ^. Ev.pesConvincedNodes)) resetHeartbeatTimer

handle :: Command -> KD.Consensus ()
handle cmd = handleSingleCommand cmd

handleBatch :: CommandBatch -> KD.Consensus ()
handleBatch cmdb@CommandBatch{..} = do
  debug "Received Command Batch"
  c <- KD.readConfig
  s <- get
  lid <- return $ KD._currentLeader s
  ct <- return $ KD._term s
  (out,_) <- runReaderT (runWriterT (handleCommandBatch cmdb)) $
             CommandEnv (KD._nodeRole s)
                        ct
                        lid
                        (KD._replayMap s)
                        (KD._nodeId c)
                        (KD._cmdBloomFilter s)
  debug "Finished processing command batch"
  case out of
    IAmLeader BatchProcessing{..} -> do
      updateLogs $ ULNew $ NewLogEntries (KD._term s) $ KD.NleEntries $  _unBPNewEntries newEntries
      unless (null $ _unBPNewEntries newEntries) $ do
        enqueueRequest $ Sender.BroadcastAE Sender.OnlySendIfFollowersAreInSync
        enqueueRequest $ Sender.BroadcastAER
      PostProcessingResult{..} <- return $! postProcessBatch lid (KD._replayMap s) alreadySeen
      -- Bloom filters can give false positives but most of the time the commands will be new, so we do a second pass to double check
      unless (null falsePositive) $ do
        updateLogs $ ULNew $ NewLogEntries (KD._term s) $ KD.NleEntries falsePositive
        enqueueRequest $ Sender.BroadcastAE Sender.OnlySendIfFollowersAreInSync
        enqueueRequest $ Sender.BroadcastAER
      KD.cmdBloomFilter .= updateBloom newEntries (KD._cmdBloomFilter s)
      quorumSize' <- view KD.quorumSize
      es <- view KD.evidenceState >>= liftIO
      when (Sender.willBroadcastAE quorumSize' (es ^. Ev.pesNodeStates) (es ^. Ev.pesConvincedNodes)) resetHeartbeatTimer
    IAmFollower BatchProcessing{..} -> do
      when (isJust lid) $ do
        enqueueRequest $ Sender.ForwardCommandToLeader (fromJust lid) $ _unBPNewEntries newEntries
      PostProcessingResult{..} <- return $! postProcessBatch lid (KD._replayMap s) alreadySeen
      unless (null falsePositive) $
        enqueueRequest $ Sender.ForwardCommandToLeader (fromJust lid) falsePositive
    IAmCandidate -> return () -- TODO: we should probably respond with something like "availability event"

data PostProcessingResult = PostProcessingResult
  { falsePositive :: ![Command]
  , alreadySeenCmds :: ![RequestKey]
  , updatedReplayMap :: !(Map RequestKey (Maybe CommandResult))
  } deriving (Eq, Show)

postProcessBatch :: Maybe NodeId -> Map.Map RequestKey (Maybe CommandResult) -> BPAlreadySeen -> PostProcessingResult
postProcessBatch mlid replays (BPAlreadySeen cs) = go cs (PostProcessingResult [] [] replays)
  where
    go [] bp = bp { falsePositive = reverse $ falsePositive bp }
    go (cmd@Command{..}:cmds) bp =
      let rk = toRequestKey "postProcessBatch" cmd
      in case Map.lookup rk replays of
        Just (Just _) -> go cmds bp {
          alreadySeenCmds =  rk : alreadySeenCmds bp }
        Just Nothing       -> go cmds bp
        _ | isNothing mlid -> go cmds bp
        Nothing -> go cmds $ bp { falsePositive = cmd : falsePositive bp
                                , updatedReplayMap = Map.insert rk Nothing $ updatedReplayMap bp }
{-# INLINE postProcessBatch #-}

updateBloom :: BPNewEntries -> Bloom RequestKey -> Bloom RequestKey
updateBloom (BPNewEntries firstPass) oldBloom = Bloom.insertList (toRequestKey "updateBloom" <$> firstPass) oldBloom
{-# INLINE updateBloom #-}
