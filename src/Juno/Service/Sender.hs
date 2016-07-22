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

import Data.Thyme.Clock (UTCTime, getCurrentTime)

import qualified Juno.Types as JT
import Juno.Types.Service.Sender as X
import qualified Juno.Types.Service.Evidence as Ev
import qualified Juno.Types.Service.Log as Log
import Juno.Types hiding (debugPrint, RaftState(..), Config(..)
  , Raft, RaftSpec(..), nodeId, sendMessage, outboundGeneral, outboundAerRvRvr
  , myPublicKey, myPrivateKey, otherNodes, nodeRole, term, Event(..), logService)


runSenderService :: Dispatch -> JT.Config -> (String -> IO ()) -> MVar Ev.PublishedEvidenceState -> IO ()
runSenderService dispatch conf debugFn mPubEvState = do
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
    , _aeReplicationLogLimit = 8000
    -- Comm Channels
    , _serviceRequestChan = dispatch ^. senderService
    , _outboundGeneral = dispatch ^. JT.outboundGeneral
    , _outboundAerRvRvr = dispatch ^. JT.outboundAerRvRvr
    -- Log Storage
    , _logService = dispatch ^. JT.logService
    , _getEvidenceState = readMVar mPubEvState
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
  debug "launch!"
  forever $ do
    sr <- liftIO $ readComm rrc
    case sr of
      (ServiceRequest' ss m) -> local (updateEnv ss) $ case m of
          BroadcastAE{..} -> do
            evState <- view getEvidenceState >>= liftIO
            sendAllAppendEntries (evState ^. Ev.pesNodeStates) (evState ^. Ev.pesConvincedNodes) _srAeBoardcastControl
          SingleAER{..} -> sendAppendEntriesResponse _srFor _srSuccess _srConvinced
          BroadcastAER -> sendAllAppendEntriesResponse
          BroadcastRV -> sendAllRequestVotes
          BroadcastRVR{..} -> sendRequestVoteResponse _srCandidate _srLastLogIndex _srVote
          SendCommandResults{..} -> sendResults _srResults
          ForwardCommandToLeader{..} -> mapM_ (sendRPC _srFor . CMD') _srCommands
      Tick t -> liftIO (pprintTock t) >>= debug

queryLogs :: Set Log.AtomicQuery -> SenderService (Map Log.AtomicQuery Log.QueryResult)
queryLogs q = do
  ls <- view logService
  mv <- liftIO newEmptyMVar
  liftIO . writeComm ls $ Log.Query q mv
  liftIO $ takeMVar mv

debug :: String -> SenderService ()
debug s = do
  dbg <- view debugPrint
  liftIO $ dbg $ "[Service|Sender] " ++ s

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

-- | Send all append entries is only needed in special circumstances. Either we have a Heartbeat event or we are getting a quick win in with CMD's
sendAllAppendEntries :: Map NodeId (LogIndex, UTCTime) -> Set NodeId -> AEBroadcastControl -> SenderService ()
sendAllAppendEntries nodeCurrentIndex' nodesThatFollow' sendIfOutOfSync = do
  ct <- view currentTerm
  myNodeId' <- view myNodeId
  yesVotes' <- view yesVotes
  oNodes <- view otherNodes
  limit' <- view aeReplicationLogLimit
  inSync' <- canBroadcastAE (length oNodes) nodeCurrentIndex' ct myNodeId' nodesThatFollow'
  synTime <- liftIO $ getCurrentTime
  case (inSync', sendIfOutOfSync) of
    (BackStreet (broadcastRPC, laggingFollowers), SendAERegardless) -> do
      -- We can't take the short cut but the AE (which is overloaded as a heartbeat grr...) still need to be sent
      -- This usually takes place when we hit a heartbeat timeout
      pubRPC broadcastRPC -- TODO: this is terrible as laggers will need a pause to catch up correctly unless we have them cache future AE
      debug "followers are out of sync, publishing latest LogEntries"
      stTime <- liftIO $ getCurrentTime
      mv <- queryLogs $ Set.map (\n -> Log.GetInfoAndEntriesAfter ((+) 1 . fst <$> Map.lookup n nodeCurrentIndex') limit') oNodes
      rpcs <- return $!
        (\target -> ( target
                    , createAppendEntries' target
                      (Log.hasQueryResult (Log.InfoAndEntriesAfter ((+) 1 .fst <$> Map.lookup target nodeCurrentIndex') limit') mv)
                      ct myNodeId' nodesThatFollow' yesVotes')
                    ) <$> Set.toList laggingFollowers
      edTime <- liftIO $ getCurrentTime
      debug $ "servicing lagging nodes, taking " ++ show (interval stTime edTime) ++ "mics to create"
      sendRpcsPeicewise rpcs (length rpcs, edTime)
      debug $ "sent all AEs Regardless: " ++ show (interval synTime edTime) ++ "mics"
    (BackStreet (broadcastRPC, _laggingFollowers), OnlySendIfFollowersAreInSync) -> do
      -- We can't just spam AE's to the followers because they can get clogged with overlapping/redundant AE's. This eventually trips an election.
      -- TODO: figure out how an out of date follower can precache LEs that it can't add to it's log yet (withough tripping an election)
      -- NB: We're doing it anyway for now, so we can test scaling accurately
      pubRPC broadcastRPC -- TODO: this is terrible as laggers will need a pause to catch up correctly unless we have them cache future AE
      edTime <- liftIO $ getCurrentTime
      debug $ "followers are out of sync, broadcasting AE anyway: " ++ show (interval synTime edTime)
    (InSync (ae, ln), _) -> do
      -- Hell yeah, we can just broadcast. We don't care about the Broadcast control if we know we can broadcast.
      -- This saves us a lot of time when node count grows.
      pubRPC $ ae
      edTime <- liftIO $ getCurrentTime
      debug $ "followers are in sync, pub AE with " ++ show ln ++ " log entries: " ++ show (interval synTime edTime)

data InSync = InSync (RPC, Int) | BackStreet (RPC, Set NodeId) deriving (Show, Eq)

willBroadcastAE :: Int
                -> Map NodeId (LogIndex, UTCTime)
                -> Set NodeId
                -> Bool
willBroadcastAE clusterSize' nodeCurrentIndex' vts =
  -- we only want to do this if we know that every node is in sync with us (the leader)
  let
    everyoneBelieves = Set.size vts == clusterSize'
    mniList = fst <$> Map.elems nodeCurrentIndex' -- get a list of where everyone is
    mniSet = Set.fromList $ mniList -- condense every Followers LI into a set
    inSync = 1 == Set.size mniSet && clusterSize' == length mniList -- if each LI is the same, then the set is a signleton
  in
    everyoneBelieves && inSync

canBroadcastAE :: Int
               -> Map NodeId (LogIndex, UTCTime)
               -> Term
               -> NodeId
               -> Set NodeId
               -> SenderService InSync
canBroadcastAE clusterSize' nodeCurrentIndex' ct myNodeId' vts =
  -- we only want to do this if we know that every node is in sync with us (the leader)
  let
    everyoneBelieves = Set.size vts == clusterSize'
    mniList = fst <$> Map.elems nodeCurrentIndex' -- get a list of where everyone is
    mniSet = Set.fromList $ mniList -- condense every Followers LI into a set
    latestFollower = head $ Set.toDescList mniSet
    laggingFollowers = Map.keysSet $ Map.filter ((/=) latestFollower . fst) nodeCurrentIndex'
    inSync = 1 == Set.size mniSet && clusterSize' == length mniList -- if each LI is the same, then the set is a signleton
    mni = head $ Set.elems mniSet -- totally unsafe but we only call it if we are going to broadcast
  in
    if everyoneBelieves && inSync
    then do
      limit' <- view aeReplicationLogLimit
      mv <- queryLogs $ Set.singleton $ Log.GetInfoAndEntriesAfter (Just $ 1 + mni) limit'
      (pli,plt, es) <- return $ Log.hasQueryResult (Log.InfoAndEntriesAfter (Just $ 1 + mni) limit') mv
      return $ InSync (AE' $ AppendEntries ct myNodeId' pli plt es Set.empty NewMsg, Seq.length es)
    else do
      limit' <- view aeReplicationLogLimit
      mv <- queryLogs $ Set.singleton $ Log.GetInfoAndEntriesAfter (Just $ 1 + latestFollower) limit'
      (pli,plt, es) <- return $ Log.hasQueryResult (Log.InfoAndEntriesAfter (Just $ 1 + latestFollower) limit') mv
      inSyncRpc <- return $! AE' $ AppendEntries ct myNodeId' pli plt es Set.empty NewMsg
      if everyoneBelieves
      then return $ BackStreet (inSyncRpc, laggingFollowers)
      else do
        oNodes' <- view otherNodes
        debug $ "non-believers exist, establishing dominance"
        return $ BackStreet (inSyncRpc, Set.union laggingFollowers (oNodes' Set.\\ vts))
{-# INLINE canBroadcastAE #-}

createAppendEntriesResponse' :: Bool -> Bool -> Term -> NodeId -> LogIndex -> ByteString -> RPC
createAppendEntriesResponse' success convinced ct myNodeId' lindex lhash =
  AER' $ AppendEntriesResponse ct myNodeId' success convinced lindex lhash NewMsg

-- this only gets used when a Follower is replying in the negative to the Leader
sendAppendEntriesResponse :: NodeId -> Bool -> Bool -> SenderService ()
sendAppendEntriesResponse target success convinced = do
  ct <- view currentTerm
  myNodeId' <- view myNodeId
  mv <- queryLogs $ Set.fromList [Log.GetMaxIndex, Log.GetLastLogHash]
  maxIndex' <- return $ Log.hasQueryResult Log.MaxIndex mv
  lastLogHash' <- return $ Log.hasQueryResult Log.LastLogHash mv
  sendRPC target $ createAppendEntriesResponse' success convinced ct myNodeId' maxIndex' lastLogHash'
  debug $ "sent AppendEntriesResponse: " ++ show ct

-- this is used for distributed evidence + updating the Leader with nodeCurrentIndex
sendAllAppendEntriesResponse :: SenderService ()
sendAllAppendEntriesResponse = do
  stTime <- liftIO $ getCurrentTime
  ct <- view currentTerm
  myNodeId' <- view myNodeId
  mv <- queryLogs $ Set.fromList [Log.GetMaxIndex, Log.GetLastLogHash]
  maxIndex' <- return $ Log.hasQueryResult Log.MaxIndex mv
  lastLogHash' <- return $ Log.hasQueryResult Log.LastLogHash mv
  aer <- return $ createAppendEntriesResponse' True True ct myNodeId' maxIndex' lastLogHash'
  sendAerRvRvr aer
  edTime <- liftIO $ getCurrentTime
  debug $ "pub AER taking " ++ show (interval stTime edTime) ++ "mics to construct"

sendRequestVoteResponse :: NodeId -> LogIndex -> Bool -> SenderService ()
sendRequestVoteResponse target logIndex' vote = do
  term' <- view currentTerm
  myNodeId' <- view myNodeId
  sendAerRvRvr $! RVR' $! RequestVoteResponse term' logIndex' myNodeId' vote target NewMsg

sendResults :: [(NodeId, CommandResponse)] -> SenderService ()
sendResults results = do
  role' <- view nodeRole
  when (role' /= Leader) $ mapM_ (debug . (++) "follower responding to commands! : " . show) results
  debug $ "sending " ++ show (length results) ++ " results"
  !res <- return $! second CMDR' <$> results
  sendRPCs res

pubRPC :: RPC -> SenderService ()
pubRPC rpc = do
  oChan <- view outboundGeneral
  myNodeId' <- view myNodeId
  privKey <- view myPrivateKey
  pubKey <- view myPublicKey
  sRpc <- return $ rpcToSignedRPC myNodeId' pubKey privKey rpc
  debug $ "issuing broadcast msg: " ++ show (_digType $ _sigDigest sRpc)
  liftIO $ writeComm oChan $ broadcastMsg [encode $ sRpc]

sendRPC :: NodeId -> RPC -> SenderService ()
sendRPC target rpc = do
  oChan <- view outboundGeneral
  myNodeId' <- view myNodeId
  privKey <- view myPrivateKey
  pubKey <- view myPublicKey
  sRpc <- return $ rpcToSignedRPC myNodeId' pubKey privKey rpc
  debug $ "issuing direct msg: " ++ show (_digType $ _sigDigest sRpc) ++ " to " ++ show (unAlias $ _alias target)
  liftIO $! writeComm oChan $! directMsg [(target, encode $ sRpc)]

sendRpcsPeicewise :: [(NodeId, RPC)] -> (Int, UTCTime) -> SenderService ()
sendRpcsPeicewise rpcs d@(total, stTime) = do
  (aFewRpcs,rest) <- return $! splitAt 8 rpcs
  if null rest
  then do
    sendRPCs aFewRpcs
    edTime <- liftIO $ getCurrentTime
    debug $ "Sent " ++ show total ++ " RPCs taking " ++ show (interval stTime edTime) ++ "mics to construct"
  else sendRpcsPeicewise rest d

sendRPCs :: [(NodeId, RPC)] -> SenderService ()
sendRPCs rpcs = do
  oChan <- view outboundGeneral
  myNodeId' <- view myNodeId
  privKey <- view myPrivateKey
  pubKey <- view myPublicKey
  msgs <- return (((\(n,msg) -> (n, encode $ rpcToSignedRPC myNodeId' pubKey privKey msg)) <$> rpcs) `using` parList rseq)
  liftIO $ writeComm oChan $! directMsg msgs

sendAerRvRvr :: RPC -> SenderService ()
sendAerRvRvr rpc = do
  oChan <- view outboundAerRvRvr
  myNodeId' <- view myNodeId
  privKey <- view myPrivateKey
  pubKey <- view myPublicKey
  sRpc <- return $ rpcToSignedRPC myNodeId' pubKey privKey rpc
  debug $ "broadcast only msg sent: "
        ++ show (_digType $ _sigDigest sRpc)
        ++ (case rpc of
              AER' v -> " for " ++ show (_aerIndex v, _aerTerm v)
              RV' v -> " for " ++ show (_rvTerm v, _rvLastLogIndex v)
              RVR' v -> " for " ++ show (_rvrTerm v, _voteGranted v)
              _ -> "")
  liftIO $! writeComm oChan $! aerRvRvrMsg [encode sRpc]
