{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Runtime.Sender
  ( sendAppendEntries
  , sendAppendEntriesResponse
  , createRequestVoteResponse
  , sendAllAppendEntries
  , sendAllAppendEntriesResponse
  , createAppendEntriesResponse
  , sendResults
  , sendRPC
  , pubRPC
  , sendAerRvRvr
  ) where

import Control.Lens
import Control.Arrow (second)
import Control.Parallel.Strategies
import Control.Monad.Writer

import Data.ByteString (ByteString)
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Sequence as Seq
import Data.Set (Set)

import qualified Data.Set as Set
import Data.Serialize

import Juno.Util.Util
import Juno.Types
import Juno.Runtime.Timer (resetLastBatchUpdate)

createAppendEntries' :: NodeId
                   -> Map NodeId LogIndex
                   -> LogState LogEntry
                   -> Term
                   -> NodeId
                   -> Set NodeId
                   -> Set RequestVoteResponse
                   -> RPC
createAppendEntries' target lNextIndex' es ct nid vts yesVotes =
  let
    mni = Map.lookup target lNextIndex'
    (pli,plt) = logInfoForNextIndex' mni es
    vts' = if Set.member target vts then Set.empty else yesVotes
  in
    AE' $ AppendEntries ct nid pli plt (getEntriesAfter' pli es) vts' NewMsg

sendAppendEntries :: NodeId -> Raft ()
sendAppendEntries target = do
  lNextIndex' <- use lNextIndex
  es <- getLogState
  ct <- use term
  nid <- viewConfig nodeId
  vts <- use lConvinced
  yesVotes <- use cYesVotes
  sendRPC target $ createAppendEntries' target lNextIndex' es ct nid vts yesVotes
  resetLastBatchUpdate
  debug $ "sendAppendEntries: " ++ show ct

sendAllAppendEntries :: Raft ()
sendAllAppendEntries = do
  lNextIndex' <- use lNextIndex
  es <- getLogState
  ct <- use term
  nid <- viewConfig nodeId
  vts <- use lConvinced
  yesVotes <- use cYesVotes
  oNodes <- viewConfig otherNodes
  case canBroadcastAE (length oNodes) lNextIndex' es ct nid vts of
    Nothing -> do -- sorry, can take the short cut
      sendRPCs $ (\target -> (target, createAppendEntries' target lNextIndex' es ct nid vts yesVotes)) <$> Set.toList oNodes
      resetLastBatchUpdate
      debug "Sent All AppendEntries"
    Just (rpc, ln) -> do -- hell yeah, we can just broadcast
      pubRPC $ rpc
      resetLastBatchUpdate
      debug $ "Broadcast New Log Entries, contained " ++ show ln ++ " log entries"

canBroadcastAE :: Int
               -> Map NodeId LogIndex
               -> LogState LogEntry
               -> Term
               -> NodeId
               -> Set NodeId
               -> Maybe (RPC, Int)
canBroadcastAE clusterSize' lNextIndex' es ct nid vts =
  -- we only want to do this if we know that every node is in sync with us (the leader)
  let
    everyoneBelieves = Set.size vts == clusterSize'
    mniList = Map.elems lNextIndex' -- get a list of where everyone is
    mniSet = Set.fromList $ mniList -- condense every Followers LI into a set
    inSync = 1 == Set.size mniSet && clusterSize' == length mniList -- if each LI is the same, then the set is a signleton
    mni = head $ Set.elems mniSet -- totally unsafe but we only call it if we are going to broadcast
    (pli,plt) = logInfoForNextIndex' (Just mni) es -- same here...
    newEntriesToReplicate = getEntriesAfter' pli es
  in
    if everyoneBelieves && inSync
    then Just (AE' $ AppendEntries ct nid pli plt newEntriesToReplicate Set.empty NewMsg, Seq.length newEntriesToReplicate)
    else Nothing

createAppendEntriesResponse' :: Bool -> Bool -> Term -> NodeId -> LogIndex -> ByteString -> RPC
createAppendEntriesResponse' success convinced ct nid lindex lhash =
  AER' $ AppendEntriesResponse ct nid success convinced lindex lhash True NewMsg

createAppendEntriesResponse :: Bool -> Bool -> Raft AppendEntriesResponse
createAppendEntriesResponse success convinced = do
  ct <- use term
  nid <- viewConfig nodeId
  es <- getLogState
  case createAppendEntriesResponse' success convinced ct nid
           (maxIndex' es) (lastLogHash' es) of
    AER' aer -> return aer
    _ -> error "deep invariant error"

-- this only gets used when a Follower is replying in the negative to the Leader
sendAppendEntriesResponse :: NodeId -> Bool -> Bool -> Raft ()
sendAppendEntriesResponse target success convinced = do
  ct <- use term
  nid <- viewConfig nodeId
  es <- getLogState
  sendRPC target $ createAppendEntriesResponse' success convinced ct nid
              (maxIndex' es) (lastLogHash' es)
  debug $ "Sent AppendEntriesResponse: " ++ show ct

-- this is used for distributed evidence + updating the Leader with lNextIndex
sendAllAppendEntriesResponse :: Raft ()
sendAllAppendEntriesResponse = do
  ct <- use term
  nid <- viewConfig nodeId
  es <- getLogState
  aer <- return $ createAppendEntriesResponse' True True ct nid (maxIndex' es) (lastLogHash' es)
  sendAerRvRvr aer

createRequestVoteResponse :: MonadWriter [String] m => Term -> LogIndex -> NodeId -> NodeId -> Bool -> m RequestVoteResponse
createRequestVoteResponse term' logIndex' myNodeId' target vote = do
  tell ["Created RequestVoteResponse: " ++ show term']
  return $ RequestVoteResponse term' logIndex' myNodeId' vote target NewMsg

sendResults :: [(NodeId, CommandResponse)] -> Raft ()
sendResults results = sendRPCs $ second CMDR' <$> results

pubRPC :: RPC -> Raft ()
pubRPC rpc = do
  send <- view sendMessage
  myNodeId <- viewConfig nodeId
  privKey <- viewConfig myPrivateKey
  pubKey <- viewConfig myPublicKey
  sRpc <- return $ rpcToSignedRPC myNodeId pubKey privKey rpc
  debug $ "Issuing broadcast msg: " ++ show (_digType $ _sigDigest sRpc)
  liftIO $ send $ broadcastMsg $ encode $ sRpc

sendRPC :: NodeId -> RPC -> Raft ()
sendRPC target rpc = do
  send <- view sendMessage
  myNodeId <- viewConfig nodeId
  privKey <- viewConfig myPrivateKey
  pubKey <- viewConfig myPublicKey
  sRpc <- return $ rpcToSignedRPC myNodeId pubKey privKey rpc
  debug $ "Issuing direct msg: " ++ show (_digType $ _sigDigest sRpc)
  liftIO $ send $ directMsg target $ encode $ sRpc

sendRPCs :: [(NodeId, RPC)] -> Raft ()
sendRPCs rpcs = do
  send <- view sendMessages
  myNodeId <- viewConfig nodeId
  privKey <- viewConfig myPrivateKey
  pubKey <- viewConfig myPublicKey
  msgs <- return (((\(n,msg) -> (n, rpcToSignedRPC myNodeId pubKey privKey msg)) <$> rpcs ) `using` parList rseq)
  --mapM_ (\(_,r) -> debug $ "Issuing (multi) direct msg: " ++ show (_digType $ _sigDigest r)) msgs
  liftIO $ send $ (\(n,r) -> directMsg n $ encode r) <$> msgs

sendAerRvRvr :: RPC -> Raft ()
sendAerRvRvr rpc = do
  send <- view sendAerRvRvrMessage
  myNodeId <- viewConfig nodeId
  privKey <- viewConfig myPrivateKey
  pubKey <- viewConfig myPublicKey
  sRpc <- return $ rpcToSignedRPC myNodeId pubKey privKey rpc
  debug $ "Issuing AeRvRvr msg: " ++ show (_digType $ _sigDigest sRpc)
  liftIO $ send $ aerRvRvrMsg $ encode $ sRpc
