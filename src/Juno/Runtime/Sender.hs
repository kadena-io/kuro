{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Runtime.Sender
  ( AEBroadcastControl(..)
  , sendAppendEntries
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


-- | This is useful for when we hit a heartbeat event but followers are out of sync.
-- Again, AE is overloaded as a Heartbeat msg as well but redundant AE's that involve crypto are wasteful/kill followers.
-- Instead we use an empty AE to elicit a AER, which we then service (as Leader of course)
createEmptyAppendEntries' :: NodeId
                   -> Map NodeId LogIndex
                   -> LogState LogEntry
                   -> Term
                   -> NodeId
                   -> Set NodeId
                   -> Set RequestVoteResponse
                   -> RPC
createEmptyAppendEntries' target lNextIndex' es ct nid vts yesVotes =
  let
    mni = Map.lookup target lNextIndex'
    (pli,plt) = logInfoForNextIndex' mni es
    vts' = if Set.member target vts then Set.empty else yesVotes
  in
    AE' $ AppendEntries ct nid pli plt Seq.empty vts' NewMsg

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
  debug $ "sendAppendEntries: " ++ show ct

data AEBroadcastControl =
  SendAERegardless |
  OnlySendIfFollowersAreInSync |
  SendEmptyAEIfOutOfSync
  deriving (Show, Eq)

-- | Send all append entries is only needed in special circumstances. Either we have a Heartbeat event or we are getting a quick win in with CMD's
sendAllAppendEntries :: AEBroadcastControl -> Raft Bool
sendAllAppendEntries sendIfOutOfSync = do
  lNextIndex' <- use lNextIndex
  es <- getLogState
  ct <- use term
  nid <- viewConfig nodeId
  vts <- use lConvinced
  yesVotes <- use cYesVotes
  oNodes <- viewConfig otherNodes
  case (canBroadcastAE (length oNodes) lNextIndex' es ct nid vts, sendIfOutOfSync) of
    (BackStreet, SendAERegardless) -> do
      -- We can't take the short cut but the AE (which is overloaded as a heartbeat grr...) still need to be sent
      -- This usually takes place when we hit a heartbeat timeout
      sendRPCs $ (\target -> (target, createAppendEntries' target lNextIndex' es ct nid vts yesVotes)) <$> Set.toList oNodes
      debug "Sent All AppendEntries"
      return True
    (BackStreet, OnlySendIfFollowersAreInSync) -> do
      -- We can't just spam AE's to the followers because they can get clogged with overlapping/redundant AE's. This eventually trips an election.
      -- TODO: figure out how an out of date follower can precache LEs that it can't add to it's log yet (withough tripping an election)
      debug "Followers are out of sync, cannot issue broadcast AE"
      return False
    (BackStreet, SendEmptyAEIfOutOfSync) -> do
      -- This is a straight up heartbeat but Raft doesn't have that RPC because... that would be too confusing?
      -- Instead, we send an Empty AE here. This should only happen when a heartbeat event is encountered but followers are out of sync
      -- TODO: track time since last contact with every node. If some node goes down/partitions we don't want that to ruin our lovely
      --       broadcast here (which it will currently). If a node is out of date for longer than a max election timeout
      --       (though +1 heartbeat may make more sense) then don't count it towards the "InSync" measurement
      sendRPCs $ (\target -> (target, createEmptyAppendEntries' target lNextIndex' es ct nid vts yesVotes)) <$> Set.toList oNodes
      debug "Followers are out of sync, cannot issue broadcast AE"
      return False
    (InSync (ae, ln), _) -> do
      -- Hell yeah, we can just broadcast. We don't care about the Broadcast control if we know we can broadcast.
      -- This saves us a lot of time when node count grows.
      pubRPC $ ae
      debug $ "Broadcast New Log Entries, contained " ++ show ln ++ " log entries"
      return True

-- I've been on a coding bender for 6 straight 12hr days
data InSync = InSync (RPC, Int) | BackStreet deriving (Show, Eq)

canBroadcastAE :: Int
               -> Map NodeId LogIndex
               -> LogState LogEntry
               -> Term
               -> NodeId
               -> Set NodeId
               -> InSync
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
    then InSync (AE' $ AppendEntries ct nid pli plt newEntriesToReplicate Set.empty NewMsg, Seq.length newEntriesToReplicate)
    else BackStreet
{-# INLINE canBroadcastAE #-}

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
sendResults results = do
  !res <- return $! second CMDR' <$> results
  sendRPCs res

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
  debug $ "Issuing direct msg: " ++ show (_digType $ _sigDigest sRpc) ++ " to " ++ show (unAlias $ _alias target)
  liftIO $! send $! directMsg target $ encode $ sRpc

sendRPCs :: [(NodeId, RPC)] -> Raft ()
sendRPCs rpcs = do
  send <- view sendMessages
  myNodeId <- viewConfig nodeId
  privKey <- viewConfig myPrivateKey
  pubKey <- viewConfig myPublicKey
  msgs <- return (((\(n,msg) -> (n, rpcToSignedRPC myNodeId pubKey privKey msg)) <$> rpcs ) `using` parList rseq)
  --mapM_ (\(_,r) -> debug $ "Issuing (multi) direct msg: " ++ show (_digType $ _sigDigest r)) msgs
  liftIO $! send $! (\(n,r) -> directMsg n $ encode r) <$> msgs

sendAerRvRvr :: RPC -> Raft ()
sendAerRvRvr rpc = do
  send <- view sendAerRvRvrMessage
  myNodeId <- viewConfig nodeId
  privKey <- viewConfig myPrivateKey
  pubKey <- viewConfig myPublicKey
  sRpc <- return $ rpcToSignedRPC myNodeId pubKey privKey rpc
  debug $ "Issuing AeRvRvr msg: " ++ show (_digType $ _sigDigest sRpc)
  liftIO $! send $! aerRvRvrMsg $ encode $ sRpc
