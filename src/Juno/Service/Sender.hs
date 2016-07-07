{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

module Juno.Service.Sender
  ( runSenderService
  , createAppendEntriesResponse' -- we need this for AER Evidence
  , willBroadcastAE
  , module X --re-export the types to make things straight forward
  ) where

import Control.Lens
import Control.Concurrent
import Control.Arrow (second)
import Control.Parallel.Strategies

import Control.Monad.Trans.Reader
import Control.Monad
import Control.Monad.IO.Class

import Data.ByteString (ByteString)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Serialize

import qualified Juno.Types as JT
import Juno.Types.Service.Sender as X
import qualified Juno.Types.Service.Log as Log
import Juno.Types hiding (debugPrint, RaftState(..), Config(..)
  , Raft, RaftSpec(..), nodeId, sendMessage, outboundGeneral, outboundAerRvRvr
  , myPublicKey, myPrivateKey, otherNodes, nodeRole, term, Event(..), logService)

runSenderService :: Dispatch -> JT.Config -> (String -> IO ()) -> IO ()
runSenderService dispatch conf debugFn = do
  s <- return $ ServiceEnv
    { _myNodeId = conf ^. JT.nodeId
    , _nodeRole = Follower
    , _otherNodes = conf ^. JT.otherNodes
    , _currentLeader = Nothing
    , _currentTerm = startTerm
    , _myPublicKey = conf ^. JT.myPublicKey
    , _myPrivateKey = conf ^. JT.myPrivateKey
    , _yesVotes = Set.empty
    , _debugPrint = debugFn
    , _aeReplicationLogLimit = 5000
    -- Comm Channels
    , _serviceRequestChan = dispatch ^. senderService
    , _outboundGeneral = dispatch ^. JT.outboundGeneral
    , _outboundAerRvRvr = dispatch ^. JT.outboundAerRvRvr
    -- Log Storage
    , _logService = dispatch ^. JT.logService
    }
  void $ liftIO $ runReaderT serviceRequests s

updateEnv :: StateSnapshot -> ServiceEnv -> ServiceEnv
updateEnv StateSnapshot{..} s = s
  { _myNodeId = _newNodeId
  , _nodeRole = _newRole
  , _otherNodes = _newOtherNodes
  , _currentLeader = _newLeader
  , _currentTerm = _newTerm
  , _myPublicKey = _newPublicKey
  , _myPrivateKey = _newPrivateKey
  , _yesVotes = _newYesVotes
  }

serviceRequests :: SenderService ()
serviceRequests = do
  rrc <- view serviceRequestChan
  debug "Begin"
  forever $ do
    sr <- liftIO $ readComm rrc
    case sr of
      (ServiceRequest' ss m) -> local (updateEnv ss) $ case m of
          SingleAE{..} -> sendAppendEntries _srFor _srNextIndex _srFollowsLeader
          BroadcastAE{..} -> sendAllAppendEntries _srlNextIndex _srConvincedNodes _srAeBoardcastControl
          SingleAER{..} -> sendAppendEntriesResponse _srFor _srSuccess _srConvinced
          BroadcastAER -> sendAllAppendEntriesResponse
          BroadcastRV -> sendAllRequestVotes
          BroadcastRVR{..} -> sendRequestVoteResponse _srCandidate _srLastLogIndex _srVote
          SendCommandResults{..} -> sendResults _srResults
          ForwardCommandToLeader{..} -> mapM_ (sendRPC _srFor . CMD') _srCommands
      Tick t -> liftIO (pprintTock t "serviceRequests") >>= debug

queryLogs :: Set Log.AtomicQuery -> SenderService (Map Log.AtomicQuery Log.QueryResult)
queryLogs q = do
  ls <- view logService
  mv <- liftIO newEmptyMVar
  liftIO . writeComm ls $ Log.Query q mv
  liftIO $ takeMVar mv

debug :: String -> SenderService ()
debug s = do
  dbg <- view debugPrint
  liftIO $ dbg $ "[SenderService] " ++ s

-- views state, but does not update
sendAllRequestVotes :: SenderService ()
sendAllRequestVotes = do
  ct <- view currentTerm
  nid <- view myNodeId
  mv <- queryLogs $ Set.fromList [Log.GetMaxIndex, Log.GetLastLogTerm]
  lastLogIndex' <- return $ Log.hasQueryResult Log.MaxIndex mv
  lastLogTerm' <- return $ Log.hasQueryResult Log.LastLogTerm mv
  debug $ "sendRequestVote: " ++ show ct
  pubRPC $ RV' $ RequestVote ct nid lastLogIndex' lastLogTerm' NewMsg

-- | This is useful for when we hit a heartbeat event but followers are out of sync.
-- Again, AE is overloaded as a Heartbeat msg as well but redundant AE's that involve crypto are wasteful/kill followers.
-- Instead we use an empty AE to elicit a AER, which we then service (as Leader of course)
--createEmptyAppendEntries' :: NodeId
--                   -> Map NodeId LogIndex
--                   -> LogState LogEntry
--                   -> Term
--                   -> NodeId
--                   -> Set NodeId
--                   -> Set RequestVoteResponse
--                   -> RPC
--createEmptyAppendEntries' target lNextIndex' es ct myNodeId' vts yesVotes' =
--  let
--    mni = Map.lookup target lNextIndex'
--    (pli,plt) = logInfoForNextIndex' mni es
--    vts' = if Set.member target vts then Set.empty else yesVotes'
--  in
--    AE' $ AppendEntries ct myNodeId' pli plt Seq.empty vts' NewMsg
createEmptyAppendEntries' :: NodeId
                          -> (LogIndex, Term)
                          -> Term
                          -> NodeId
                          -> Set NodeId
                          -> Set RequestVoteResponse
                          -> RPC
createEmptyAppendEntries' target (pli, plt) ct myNodeId' vts yesVotes' =
  let
    vts' = if Set.member target vts then Set.empty else yesVotes'
  in
    AE' $ AppendEntries ct myNodeId' pli plt Seq.empty vts' NewMsg

createAppendEntries' :: NodeId
                     -> (LogIndex, Term, Seq LogEntry)
                     -> Term
                     -> NodeId
                     -> Set NodeId
                     -> Set RequestVoteResponse
                     -> RPC
createAppendEntries' target (pli, plt, es) ct myNodeId' vts yesVotes' =
  let
    vts' = if Set.member target vts then Set.empty else yesVotes'
  in
    AE' $ AppendEntries ct myNodeId' pli plt es vts' NewMsg

sendAppendEntries :: NodeId -> Maybe LogIndex -> Bool -> SenderService ()
sendAppendEntries target lNextIndex' isConvinced = do
  limit' <- view aeReplicationLogLimit
  mv <- queryLogs $ Set.singleton $ Log.GetInfoAndEntriesAfter lNextIndex' limit'
  (pli,plt,es) <- return $ Log.hasQueryResult (Log.InfoAndEntriesAfter lNextIndex' limit') mv
  vts' <- if isConvinced then return $ Set.empty else view yesVotes
  ct <- view currentTerm
  myNodeId' <- view myNodeId
  sendRPC target $ AE' $ AppendEntries ct myNodeId' pli plt es vts' NewMsg
--   createAppendEntries' target lNextIndex' es ct myNodeId' lConvinced' yesVotes'
  debug $ "sendAppendEntries: " ++ show ct

-- | Send all append entries is only needed in special circumstances. Either we have a Heartbeat event or we are getting a quick win in with CMD's
sendAllAppendEntries :: Map NodeId LogIndex -> Set NodeId -> AEBroadcastControl -> SenderService ()
sendAllAppendEntries lNextIndex' lConvinced' sendIfOutOfSync = do
  ct <- view currentTerm
  myNodeId' <- view myNodeId
  yesVotes' <- view yesVotes
  oNodes <- view otherNodes
  limit' <- view aeReplicationLogLimit
  inSync' <- canBroadcastAE (length oNodes) lNextIndex' ct myNodeId' lConvinced'
  case (inSync', sendIfOutOfSync) of
    (BackStreet, SendAERegardless) -> do
      -- We can't take the short cut but the AE (which is overloaded as a heartbeat grr...) still need to be sent
      -- This usually takes place when we hit a heartbeat timeout
      mv <- queryLogs $ Set.map (\n -> Log.GetInfoAndEntriesAfter (Map.lookup n lNextIndex') limit') oNodes
      sendRPCs $ (\target ->
                    ( target
                    , createAppendEntries' target
                      (Log.hasQueryResult (Log.InfoAndEntriesAfter (Map.lookup target lNextIndex') limit') mv)
                      ct myNodeId' lConvinced' yesVotes')
                 ) <$> Set.toList oNodes
      debug "Sent All AppendEntries"
    (BackStreet, OnlySendIfFollowersAreInSync) -> do
      -- We can't just spam AE's to the followers because they can get clogged with overlapping/redundant AE's. This eventually trips an election.
      -- TODO: figure out how an out of date follower can precache LEs that it can't add to it's log yet (withough tripping an election)
      debug "Followers are out of sync, cannot issue broadcast AE"
    (BackStreet, SendEmptyAEIfOutOfSync) -> do
      -- This is a straight up heartbeat but Raft doesn't have that RPC because... that would be too confusing?
      -- Instead, we send an Empty AE here. This should only happen when a heartbeat event is encountered but followers are out of sync
      -- TODO: track time since last contact with every node. If some node goes down/partitions we don't want that to ruin our lovely
      --       broadcast here (which it will currently). If a node is out of date for longer than a max election timeout
      --       (though +1 heartbeat may make more sense) then don't count it towards the "InSync" measurement
      mv <- queryLogs $ Set.map (\n -> Log.GetLogInfoForNextIndex (Map.lookup n lNextIndex')) oNodes
      sendRPCs $ (\target ->
                    ( target
                    , createEmptyAppendEntries' target
                      (Log.hasQueryResult (Log.LogInfoForNextIndex (Map.lookup target lNextIndex')) mv)
                      ct myNodeId' lConvinced' yesVotes')
                 ) <$> Set.toList oNodes
      debug "Followers are out of sync, cannot issue broadcast AE"
    (InSync (ae, ln), _) -> do
      -- Hell yeah, we can just broadcast. We don't care about the Broadcast control if we know we can broadcast.
      -- This saves us a lot of time when node count grows.
      pubRPC $ ae
      debug $ "Broadcast New Log Entries, contained " ++ show ln ++ " log entries"

-- I've been on a coding bender for 6 straight 12hr days
data InSync = InSync (RPC, Int) | BackStreet deriving (Show, Eq)

willBroadcastAE :: Int
                -> Map NodeId LogIndex
                -> Set NodeId
                -> Bool
willBroadcastAE clusterSize' lNextIndex' vts =
  -- we only want to do this if we know that every node is in sync with us (the leader)
  let
    everyoneBelieves = Set.size vts == clusterSize'
    mniList = Map.elems lNextIndex' -- get a list of where everyone is
    mniSet = Set.fromList $ mniList -- condense every Followers LI into a set
    inSync = 1 == Set.size mniSet && clusterSize' == length mniList -- if each LI is the same, then the set is a signleton
  in
    everyoneBelieves && inSync

canBroadcastAE :: Int
               -> Map NodeId LogIndex
               -> Term
               -> NodeId
               -> Set NodeId
               -> SenderService InSync
canBroadcastAE clusterSize' lNextIndex' ct myNodeId' vts =
  -- we only want to do this if we know that every node is in sync with us (the leader)
  let
    everyoneBelieves = Set.size vts == clusterSize'
    mniList = Map.elems lNextIndex' -- get a list of where everyone is
    mniSet = Set.fromList $ mniList -- condense every Followers LI into a set
    inSync = 1 == Set.size mniSet && clusterSize' == length mniList -- if each LI is the same, then the set is a signleton
    mni = head $ Set.elems mniSet -- totally unsafe but we only call it if we are going to broadcast
  in
    if everyoneBelieves && inSync
    then do
      limit' <- view aeReplicationLogLimit
      mv <- queryLogs $ Set.singleton $ Log.GetInfoAndEntriesAfter (Just mni) limit'
      (pli,plt, es) <- return $ Log.hasQueryResult (Log.InfoAndEntriesAfter (Just mni) limit') mv
      return $ InSync (AE' $ AppendEntries ct myNodeId' pli plt es Set.empty NewMsg, Seq.length es)
    else return BackStreet
{-# INLINE canBroadcastAE #-}

createAppendEntriesResponse' :: Bool -> Bool -> Term -> NodeId -> LogIndex -> ByteString -> RPC
createAppendEntriesResponse' success convinced ct myNodeId' lindex lhash =
  AER' $ AppendEntriesResponse ct myNodeId' success convinced lindex lhash True NewMsg

-- this only gets used when a Follower is replying in the negative to the Leader
sendAppendEntriesResponse :: NodeId -> Bool -> Bool -> SenderService ()
sendAppendEntriesResponse target success convinced = do
  ct <- view currentTerm
  myNodeId' <- view myNodeId
  mv <- queryLogs $ Set.fromList [Log.GetMaxIndex, Log.GetLastLogHash]
  maxIndex' <- return $ Log.hasQueryResult Log.MaxIndex mv
  lastLogHash' <- return $ Log.hasQueryResult Log.LastLogHash mv
  sendRPC target $ createAppendEntriesResponse' success convinced ct myNodeId' maxIndex' lastLogHash'
  debug $ "Sent AppendEntriesResponse: " ++ show ct

-- this is used for distributed evidence + updating the Leader with lNextIndex
sendAllAppendEntriesResponse :: SenderService ()
sendAllAppendEntriesResponse = do
  ct <- view currentTerm
  myNodeId' <- view myNodeId
  mv <- queryLogs $ Set.fromList [Log.GetMaxIndex, Log.GetLastLogHash]
  maxIndex' <- return $ Log.hasQueryResult Log.MaxIndex mv
  lastLogHash' <- return $ Log.hasQueryResult Log.LastLogHash mv
  aer <- return $ createAppendEntriesResponse' True True ct myNodeId' maxIndex' lastLogHash'
  sendAerRvRvr aer

sendRequestVoteResponse :: NodeId -> LogIndex -> Bool -> SenderService ()
sendRequestVoteResponse target logIndex' vote = do
  term' <- view currentTerm
  myNodeId' <- view myNodeId
  sendAerRvRvr $! RVR' $! RequestVoteResponse term' logIndex' myNodeId' vote target NewMsg

sendResults :: [(NodeId, CommandResponse)] -> SenderService ()
sendResults results = do
  role' <- view nodeRole
  when (role' /= Leader) $ mapM_ (debug . (++) "Follower responding to commands! : " . show) results
  debug $ "###====>    Sending " ++ show (length results) ++ " results"
  !res <- return $! second CMDR' <$> results
  sendRPCs res

pubRPC :: RPC -> SenderService ()
pubRPC rpc = do
  oChan <- view outboundGeneral
  myNodeId' <- view myNodeId
  privKey <- view myPrivateKey
  pubKey <- view myPublicKey
  sRpc <- return $ rpcToSignedRPC myNodeId' pubKey privKey rpc
  debug $ "Issuing broadcast msg: " ++ show (_digType $ _sigDigest sRpc)
  liftIO $ writeComm oChan $ broadcastMsg $ encode $ sRpc

sendRPC :: NodeId -> RPC -> SenderService ()
sendRPC target rpc = do
  oChan <- view outboundGeneral
  myNodeId' <- view myNodeId
  privKey <- view myPrivateKey
  pubKey <- view myPublicKey
  sRpc <- return $ rpcToSignedRPC myNodeId' pubKey privKey rpc
  debug $ "Issuing direct msg: " ++ show (_digType $ _sigDigest sRpc) ++ " to " ++ show (unAlias $ _alias target)
  liftIO $! writeComm oChan $! directMsg target $ encode $ sRpc

sendRPCs :: [(NodeId, RPC)] -> SenderService ()
sendRPCs rpcs = do
  oChan <- view outboundGeneral
  myNodeId' <- view myNodeId
  privKey <- view myPrivateKey
  pubKey <- view myPublicKey
  msgs <- return (((\(n,msg) -> (n, rpcToSignedRPC myNodeId' pubKey privKey msg)) <$> rpcs ) `using` parList rseq)
  --mapM_ (\(_,r) -> debug $ "Issuing (multi) direct msg: " ++ show (_digType $ _sigDigest r)) msgs
  liftIO $ mapM_ (writeComm oChan) $! (\(n,r) -> directMsg n $ encode r) <$> msgs

sendAerRvRvr :: RPC -> SenderService ()
sendAerRvRvr rpc = do
  oChan <- view outboundAerRvRvr
  myNodeId' <- view myNodeId
  privKey <- view myPrivateKey
  pubKey <- view myPublicKey
  sRpc <- return $ rpcToSignedRPC myNodeId' pubKey privKey rpc
  debug $ "Broadcast only msg sent: "
        ++ show (_digType $ _sigDigest sRpc)
        ++ (case rpc of
              AER' v -> " for " ++ show (_aerIndex v, _aerTerm v, _aerWasVerified v)
              RV' v -> " for " ++ show (_rvTerm v, _rvLastLogIndex v)
              RVR' v -> " for " ++ show (_rvrTerm v, _voteGranted v)
              _ -> "")
  liftIO $! writeComm oChan $! aerRvRvrMsg $ encode $ sRpc
