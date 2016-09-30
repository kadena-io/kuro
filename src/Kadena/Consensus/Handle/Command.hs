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
import Kadena.Util.Util (getCmdSigOrInvariantError, updateLogs, enqueueRequest, debug, makeCommandResponse')
import Kadena.Runtime.Timer (resetHeartbeatTimer)
import qualified Kadena.Types as KD

import qualified Kadena.Service.Sender as Sender
import qualified Kadena.Service.Evidence as Ev

data CommandEnv = CommandEnv {
      _nodeRole :: Role
    , _term :: Term
    , _currentLeader :: Maybe NodeId
    , _replayMap :: Map.Map (NodeId, Signature) (Maybe CommandResult)
    , _nodeId :: NodeId
    , _cmdBloomFilter :: Bloom (NodeId,Signature)
}
makeLenses ''CommandEnv

data CommandOut =
    UnknownLeader |
    RetransmitToLeader { _leaderId :: NodeId } |
    CommitAndPropagate {
      _newEntry :: NewLogEntries
    , _replayKey :: (NodeId, Signature)
    } |
    AlreadySeen |
    SendCommandResponse {
      _clientId :: NodeId
    , _commandReponse :: CommandResponse
    }

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
  replays <- view replayMap
  nid <- view nodeId
  cmdSig <- return $ getCmdSigOrInvariantError "handleCommand" cmd
  case (Map.lookup (_cmdClientId, cmdSig) replays, r, mlid) of
    (Just (Just result), _, _) -> do
      cmdr <- return $ makeCommandResponse' nid cmd result
      return . SendCommandResponse _cmdClientId $ cmdr 1
      -- we have already committed this request, so send the result to the client
    (Just Nothing, _, _) ->
      -- we have already seen this request, but have not yet committed it
      -- nothing to do
      return AlreadySeen
    (_, Leader, _) ->
      -- we're the leader, so append this to our log with the current term
      -- and propagate it to replicas
      return $ CommitAndPropagate (NewLogEntries ct (KD.NleEntries [cmd])) (_cmdClientId, cmdSig)
    (_, _, Just lid) ->
      -- we're not the leader, but we know who the leader is, so forward this
      -- command (don't sign it ourselves, as it comes from the client)
      return $ RetransmitToLeader lid
    (_, _, Nothing) ->
      -- we're not the leader, and we don't know who the leader is, so can't do
      -- anything
      return UnknownLeader

filterBatch :: Bloom (NodeId, Signature) -> Commands -> BatchProcessing
filterBatch bfilter (Commands cs) = BatchProcessing (BPNewEntries brandNew) (BPAlreadySeen likelySeen)
  where
    cmdSig c = getCmdSigOrInvariantError "handleCommand" c
    probablyAlreadySaw cmd@Command{..} =
      -- forcing the inside of an either is notoriously hard. in' is trying to at least force the majority of the work
      let in' = Bloom.elem (_cmdClientId, cmdSig cmd) bfilter
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
    (SendCommandResponse cid res) -> enqueueRequest $ Sender.SendCommandResults [(cid,res)]
    (CommitAndPropagate newEntry replayKey) -> do
      updateLogs $ ULNew newEntry
      KD.replayMap %= Map.insert replayKey Nothing
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
      PostProcessingResult{..} <- return $! postProcessBatch (KD._nodeId c) lid (KD._replayMap s) alreadySeen
      -- Bloom filters can give false positives but most of the time the commands will be new, so we do a second pass to double check
      unless (null falsePositive) $ do
        updateLogs $ ULNew $ NewLogEntries (KD._term s) $ KD.NleEntries falsePositive
        enqueueRequest $ Sender.BroadcastAE Sender.OnlySendIfFollowersAreInSync
        enqueueRequest $ Sender.BroadcastAER
      unless (null responseToOldCmds) $
        enqueueRequest $ Sender.SendCommandResults responseToOldCmds
      KD.replayMap .= updatedReplayMap
      KD.cmdBloomFilter .= updateBloom newEntries (KD._cmdBloomFilter s)
      quorumSize' <- view KD.quorumSize
      es <- view KD.evidenceState >>= liftIO
      when (Sender.willBroadcastAE quorumSize' (es ^. Ev.pesNodeStates) (es ^. Ev.pesConvincedNodes)) resetHeartbeatTimer
    IAmFollower BatchProcessing{..} -> do
      when (isJust lid) $ do
        enqueueRequest $ Sender.ForwardCommandToLeader (fromJust lid) $ _unBPNewEntries newEntries
      PostProcessingResult{..} <- return $! postProcessBatch (KD._nodeId c) lid (KD._replayMap s) alreadySeen
      unless (null falsePositive) $
        enqueueRequest $ Sender.ForwardCommandToLeader (fromJust lid) falsePositive
      unless (null responseToOldCmds) $
        enqueueRequest $ Sender.SendCommandResults responseToOldCmds
    IAmCandidate -> return () -- TODO: we should probably respond with something like "availability event"

data PostProcessingResult = PostProcessingResult
  { falsePositive :: ![Command]
  , responseToOldCmds :: ![(NodeId, CommandResponse)]
  , updatedReplayMap :: !(Map (NodeId,Signature) (Maybe CommandResult))
  } deriving (Eq, Show)

postProcessBatch :: NodeId -> Maybe NodeId -> Map.Map (NodeId, Signature) (Maybe CommandResult) -> BPAlreadySeen -> PostProcessingResult
postProcessBatch nid mlid replays (BPAlreadySeen cs) = go cs (PostProcessingResult [] [] replays)
  where
    cmdSig c = getCmdSigOrInvariantError "postProcessBatch" c
    go [] bp = bp { falsePositive = reverse $ falsePositive bp }
    go (cmd@Command{..}:cmds) bp = case Map.lookup (_cmdClientId, cmdSig cmd) replays of
      Just (Just result) -> go cmds bp {
        responseToOldCmds = (_cmdClientId, makeCommandResponse' nid cmd result 1) : responseToOldCmds bp }
      Just Nothing       -> go cmds bp
      _ | isNothing mlid -> go cmds bp
      Nothing -> go cmds $ bp { falsePositive = cmd : falsePositive bp
                              , updatedReplayMap = Map.insert (_cmdClientId, cmdSig cmd) Nothing $ updatedReplayMap bp }
{-# INLINE postProcessBatch #-}

updateBloom :: BPNewEntries -> Bloom (NodeId, Signature) -> Bloom (NodeId, Signature)
updateBloom (BPNewEntries firstPass) oldBloom = Bloom.insertList (grabKey <$> firstPass) oldBloom
  where
    cmdSig c = getCmdSigOrInvariantError "updateBloom" c
    grabKey cmd@Command{..} = (_cmdClientId, cmdSig cmd)
{-# INLINE updateBloom #-}
