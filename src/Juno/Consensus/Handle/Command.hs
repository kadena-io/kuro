{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Consensus.Handle.Command
    (handle
    ,handleBatch)
    where

import Control.Lens
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer


import qualified Data.Map.Strict as Map

import Data.Maybe (isNothing, isJust, fromJust)

import Juno.Consensus.Commit (makeCommandResponse')

import Juno.Consensus.Handle.Types
import Juno.Util.Util (getCmdSigOrInvariantError, updateLogs, enqueueRequest)
import Juno.Runtime.Timer (resetHeartbeatTimer)
import qualified Juno.Types as JT

import qualified Juno.Service.Sender as Sender
import qualified Juno.Service.Evidence as Ev

data CommandEnv = CommandEnv {
      _nodeRole :: Role
    , _term :: Term
    , _currentLeader :: Maybe NodeId
    , _replayMap :: Map.Map (NodeId, Signature) (Maybe CommandResult)
    , _nodeId :: NodeId
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

data BatchProcessing = BatchProcessing
  { newEntries :: ![Command]
  , serviceAlreadySeen :: ![(NodeId, CommandResponse)]
  , updatedReplays :: (Map.Map (NodeId, Signature) (Maybe CommandResult))
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
      cmdr <- return $ makeCommandResponse' nid mlid cmd result
      return . SendCommandResponse _cmdClientId $ cmdr 1
      -- we have already committed this request, so send the result to the client
    (Just Nothing, _, _) ->
      -- we have already seen this request, but have not yet committed it
      -- nothing to do
      return AlreadySeen
    (_, Leader, _) ->
      -- we're the leader, so append this to our log with the current term
      -- and propagate it to replicas
      return $ CommitAndPropagate (NewLogEntries ct [cmd]) (_cmdClientId, cmdSig)
    (_, _, Just lid) ->
      -- we're not the leader, but we know who the leader is, so forward this
      -- command (don't sign it ourselves, as it comes from the client)
      return $ RetransmitToLeader lid
    (_, _, Nothing) ->
      -- we're not the leader, and we don't know who the leader is, so can't do
      -- anything
      return UnknownLeader

filterBatch :: NodeId -> Maybe NodeId -> Map.Map (NodeId, Signature) (Maybe CommandResult) -> [Command] -> BatchProcessing
filterBatch nid mlid replays cs = go cs (BatchProcessing [] [] replays)
  where
    cmdSig c = getCmdSigOrInvariantError "handleCommand" c
    -- TODO: this suck that I have to reverse the list at the end...
    go [] bp = bp { newEntries = reverse $ newEntries bp }
    go (cmd@Command{..}:cmds) bp = case (Map.lookup (_cmdClientId, cmdSig cmd) replays) of
      Just (Just result) -> go cmds bp {
        serviceAlreadySeen = (_cmdClientId, makeCommandResponse' nid mlid cmd result 1) : (serviceAlreadySeen bp) }
      -- We drop the command if the message is pending application or we don't know who to forward to
      Just Nothing       -> go cmds bp
      _ | isNothing mlid -> go cmds bp
      Nothing -> go cmds bp { newEntries = cmd : (newEntries bp)
                            , updatedReplays = Map.insert (_cmdClientId, cmdSig cmd) Nothing $ updatedReplays bp }

handleCommandBatch :: (MonadReader CommandEnv m,MonadWriter [String] m) => CommandBatch -> m CommandBatchOut
handleCommandBatch CommandBatch{..} = do
  tell ["got a command RPC"]
  r <- view nodeRole
  mlid <- view currentLeader
  replays <- view replayMap
  nid <- view nodeId
  return $! case r of
    Leader -> IAmLeader $ filterBatch nid mlid replays _cmdbBatch
    Follower -> IAmFollower $ filterBatch nid mlid replays _cmdbBatch
    Candidate -> IAmCandidate

handleSingleCommand :: Command -> JT.Raft ()
handleSingleCommand cmd = do
  c <- JT.readConfig
  s <- get
  (out,_) <- runReaderT (runWriterT (handleCommand cmd)) $
             CommandEnv (JT._nodeRole s)
                        (JT._term s)
                        (JT._currentLeader s)
                        (JT._replayMap s)
                        (JT._nodeId c)
  case out of
    UnknownLeader -> return () -- TODO: we should probably respond with something like "availability event"
    AlreadySeen -> return () -- TODO: we should probably respond with something like "transaction still pending"
    (RetransmitToLeader lid) -> enqueueRequest $ Sender.ForwardCommandToLeader lid [cmd]
    (SendCommandResponse cid res) -> enqueueRequest $ Sender.SendCommandResults [(cid,res)]
    (CommitAndPropagate newEntry replayKey) -> do
      updateLogs $ ULNew newEntry
      JT.replayMap %= Map.insert replayKey Nothing
      enqueueRequest $ Sender.BroadcastAE Sender.OnlySendIfFollowersAreInSync
      enqueueRequest $ Sender.BroadcastAER
      quorumSize' <- view JT.quorumSize
      es <- view JT.evidenceState >>= liftIO
      when (Sender.willBroadcastAE quorumSize' (es ^. Ev.esNodeStates) (es ^. Ev.esConvincedNodes)) resetHeartbeatTimer

handle :: Command -> JT.Raft ()
handle cmd = handleSingleCommand cmd

handleBatch :: CommandBatch -> JT.Raft ()
handleBatch cmdb@CommandBatch{..} = do
  c <- JT.readConfig
  s <- get
  lid <- return $ JT._currentLeader s
  ct <- return $ JT._term s
  (out,_) <- runReaderT (runWriterT (handleCommandBatch cmdb)) $
             CommandEnv (JT._nodeRole s)
                        ct
                        lid
                        (JT._replayMap s)
                        (JT._nodeId c)
  case out of
    IAmLeader BatchProcessing{..} -> do
      updateLogs $ ULNew $ NewLogEntries (JT._term s) newEntries
      JT.replayMap .= updatedReplays
      unless (null newEntries) $ do
        enqueueRequest $ Sender.BroadcastAE Sender.OnlySendIfFollowersAreInSync
        enqueueRequest $ Sender.BroadcastAER
      unless (null serviceAlreadySeen) $ enqueueRequest $ Sender.SendCommandResults serviceAlreadySeen
      quorumSize' <- view JT.quorumSize
      es <- view JT.evidenceState >>= liftIO
      when (Sender.willBroadcastAE quorumSize' (es ^. Ev.esNodeStates) (es ^. Ev.esConvincedNodes)) resetHeartbeatTimer
    IAmFollower BatchProcessing{..} -> do
      when (isJust lid) $ enqueueRequest $ Sender.ForwardCommandToLeader (fromJust lid) newEntries
      unless (null serviceAlreadySeen) $ enqueueRequest $ Sender.SendCommandResults serviceAlreadySeen
    IAmCandidate -> return () -- TODO: we should probably respond with something like "availability event"
