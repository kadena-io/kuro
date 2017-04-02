{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Sender.Service
  ( SenderService
  , ServiceEnv(..), myNodeId, currentLeader, currentTerm, myPublicKey
  , myPrivateKey, yesVotes, debugPrint, serviceRequestChan, outboundGeneral
  , logService, otherNodes, nodeRole, getEvidenceState, publishMetric, aeReplicationLogLimit
  , runSenderService
  , createAppendEntriesResponse' -- we need this for AER Evidence
  , willBroadcastAE
  , module X --re-export the types to make things straight forward
  ) where

import Control.Lens
import Control.Concurrent
import Control.Parallel.Strategies

import Control.Monad.Trans.Reader
import Control.Monad
import Control.Monad.IO.Class

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Serialize

import Data.Thyme.Clock (UTCTime, getCurrentTime)

import Kadena.Types hiding (debugPrint, ConsensusState(..), Config(..)
  , Consensus, ConsensusSpec(..), nodeId, sendMessage, outboundGeneral
  , myPublicKey, myPrivateKey, otherNodes, nodeRole, term, Event(..)
  , logService, publishMetric, currentLeader)
import qualified Kadena.Types as KD

import qualified Kadena.Types.Spec as Spec

import Kadena.Log.Types (LogServiceChannel)
import qualified Kadena.Log.Types as Log
import Kadena.Evidence.Spec (PublishedEvidenceState)
import qualified Kadena.Evidence.Spec as Ev

import Kadena.Sender.Types as X

data ServiceEnv = ServiceEnv
  { _myNodeId :: !NodeId
  , _nodeRole :: !Role
  , _otherNodes :: !(Set NodeId)
  , _currentLeader :: !(Maybe NodeId)
  , _currentTerm :: !Term
  , _myPublicKey :: !PublicKey
  , _myPrivateKey :: !PrivateKey
  , _yesVotes :: !(Set RequestVoteResponse)
  , _debugPrint :: !(String -> IO ())
  , _aeReplicationLogLimit :: Int
  -- Comm Channels
  , _serviceRequestChan :: !SenderServiceChannel
  , _outboundGeneral :: !OutboundGeneralChannel
  -- Log Storage
  , _logService :: !LogServiceChannel
  -- Evidence Thread's Published State
  , _getEvidenceState :: !(IO PublishedEvidenceState)
  , _publishMetric :: !(Metric -> IO ())
  , _config :: !GlobalConfigTMVar
  , _pubCons :: !(MVar Spec.PublishedConsensus)
  }
makeLenses ''ServiceEnv

type SenderService = ReaderT ServiceEnv IO

getStateSnapshot :: GlobalConfigTMVar -> MVar PublishedConsensus -> IO StateSnapshot
getStateSnapshot conf' pcons' = do
  conf <- _gcConfig <$> readMVar conf'
  st <- readMVar pcons'
  return $! StateSnapshot
    { _newNodeId = conf ^. KD.nodeId
    , _newRole = st ^. Spec.pcRole
    , _newOtherNodes = conf ^. KD.otherNodes
    , _newLeader = st ^. Spec.pcLeader
    , _newTerm = st ^. Spec.pcTerm
    , _newPublicKey = conf ^. KD.myPublicKey
    , _newPrivateKey = conf ^. KD.myPrivateKey
    , _newYesVotes = st ^. Spec.pcYesVotes
    }

runSenderService
  :: Dispatch
  -> GlobalConfigTMVar
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> MVar Ev.PublishedEvidenceState
  -> MVar Spec.PublishedConsensus
  -> IO ()
runSenderService dispatch iorConf debugFn publishMetric' mPubEvState mPubCons = do
  conf <- _gcConfig <$> readMVar iorConf
  s <- return $ ServiceEnv
    { _myNodeId = conf ^. KD.nodeId
    , _nodeRole = Follower
    , _otherNodes = conf ^. KD.otherNodes
    , _currentLeader = Nothing
    , _currentTerm = startTerm
    , _myPublicKey = conf ^. KD.myPublicKey
    , _myPrivateKey = conf ^. KD.myPrivateKey
    , _yesVotes = Set.empty
    , _debugPrint = debugFn
    , _aeReplicationLogLimit = conf ^. KD.aeBatchSize
    -- Comm Channels
    , _serviceRequestChan = dispatch ^. senderService
    , _outboundGeneral = dispatch ^. KD.outboundGeneral
    -- Log Storage
    , _logService = dispatch ^. KD.logService
    , _getEvidenceState = readMVar mPubEvState
    , _publishMetric = publishMetric'
    , _config = iorConf
    , _pubCons = mPubCons
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

snapshotStateExternal :: SenderService (StateSnapshot)
snapshotStateExternal = do
  mPubCons <- view pubCons
  conf <- view config
  liftIO $ getStateSnapshot conf mPubCons

serviceRequests :: SenderService ()
serviceRequests = do
  rrc <- view serviceRequestChan
  debug "launch!"
  forever $ do
    sr <- liftIO $ readComm rrc
    case sr of
      SendAllAppendEntriesResponse{..} -> do
        newSt <- snapshotStateExternal
        local (updateEnv newSt) $ do
          stTime <- liftIO $ getCurrentTime
          sendAllAppendEntriesResponse' (Just _srIssuedTime) stTime _srLastLogHash _srMaxIndex
      ForwardCommandToLeader{..} -> do
        newSt <- snapshotStateExternal
        local (updateEnv newSt) $ do
          ldr <- view currentLeader
          case ldr of
            Nothing -> debug $ "Leader is down, unable to forward commands. Dropping..."
            Just ldr' -> do
              debug $ "fowarding " ++ show (length $ _newCmd $ _srCommands) ++ "commands to leader"
              sendRPC ldr' $ NEW' _srCommands
      (ServiceRequest' ss m) -> local (updateEnv ss) $ case m of
          BroadcastAE{..} -> do
            evState <- view getEvidenceState >>= liftIO
            sendAllAppendEntries (evState ^. Ev.pesNodeStates) (evState ^. Ev.pesConvincedNodes) _srAeBoardcastControl
          EstablishDominance -> establishDominance
          SingleAER{..} -> sendAppendEntriesResponse _srFor _srSuccess _srConvinced
          BroadcastAER -> sendAllAppendEntriesResponse
          BroadcastRV rv -> sendAllRequestVotes rv
          BroadcastRVR{..} -> sendRequestVoteResponse _srCandidate _srHeardFromLeader _srVote
      Heart t -> liftIO (pprintBeat t) >>= debug

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
sendAllRequestVotes :: RequestVote -> SenderService ()
sendAllRequestVotes rv = do
  pubRPC $ RV' $ rv

createAppendEntries' :: NodeId
                     -> (LogIndex, Term, LogEntries)
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

establishDominance :: SenderService ()
establishDominance = do
  debug "establishing general dominance"
  stTime <- liftIO $ getCurrentTime
  ct <- view currentTerm
  myNodeId' <- view myNodeId
  yesVotes' <- view yesVotes
  mv <- queryLogs $ Set.fromList [Log.GetMaxIndex, Log.GetLastLogTerm]
  pli <- return $! Log.hasQueryResult Log.MaxIndex mv
  plt <- return $! Log.hasQueryResult Log.LastLogTerm mv
  rpc <- return $! AE' $ AppendEntries ct myNodeId' pli plt Log.lesEmpty yesVotes' NewMsg
  edTime <- liftIO $ getCurrentTime
  pubRPC rpc
  debug $ "asserted dominance: " ++ show (interval stTime edTime) ++ "mics"


-- | Send all append entries is only needed in special circumstances. Either we have a Heartbeat event or we are getting a quick win in with CMD's
sendAllAppendEntries :: Map NodeId (LogIndex, UTCTime) -> Set NodeId -> AEBroadcastControl -> SenderService ()
sendAllAppendEntries nodeCurrentIndex' nodesThatFollow' sendIfOutOfSync = do
  startTime' <- liftIO $ getCurrentTime
  ct <- view currentTerm
  myNodeId' <- view myNodeId
  yesVotes' <- view yesVotes
  oNodes <- view otherNodes
  limit' <- view aeReplicationLogLimit
  inSync' <- canBroadcastAE (length oNodes) nodeCurrentIndex' ct myNodeId' nodesThatFollow'
  synTime' <- liftIO $ getCurrentTime
  case (inSync', sendIfOutOfSync) of
    (BackStreet (broadcastRPC, laggingFollowers), SendAERegardless) -> do
      -- We can't take the short cut but the AE (which is overloaded as a heartbeat grr...) still need to be sent
      -- This usually takes place when we hit a heartbeat timeout
      pubRPC broadcastRPC -- TODO: this is terrible as laggers will need a pause to catch up correctly unless we have them cache future AE
      debug "followers are out of sync, publishing latest LogEntries"
      mv <- queryLogs $ Set.map (\n -> Log.GetInfoAndEntriesAfter ((+) 1 . fst <$> Map.lookup n nodeCurrentIndex') limit') oNodes
      rpcs <- return $!
        (\target -> ( target
                    , createAppendEntries' target
                      (Log.hasQueryResult (Log.InfoAndEntriesAfter ((+) 1 .fst <$> Map.lookup target nodeCurrentIndex') limit') mv)
                      ct myNodeId' nodesThatFollow' yesVotes')
                    ) <$> Set.toList laggingFollowers
      endTime' <- liftIO $ getCurrentTime
      debug $ "AE servicing lagging nodes, taking " ++ printInterval startTime' endTime' ++ " to create (syncTime=" ++ printInterval startTime' synTime' ++ ")"
      sendRpcsPeicewise rpcs (length rpcs, endTime')
      debug $ "AE sent Regardless"
    (BackStreet (broadcastRPC, _laggingFollowers), OnlySendIfFollowersAreInSync) -> do
      -- We can't just spam AE's to the followers because they can get clogged with overlapping/redundant AE's. This eventually trips an election.
      -- TODO: figure out how an out of date follower can precache LEs that it can't add to it's log yet (withough tripping an election)
      -- NB: We're doing it anyway for now, so we can test scaling accurately
      pubRPC broadcastRPC -- TODO: this is terrible as laggers will need a pause to catch up correctly unless we have them cache future AE
      endTime' <- liftIO $ getCurrentTime
      debug $ "followers are out of sync, broadcasting AE anyway: " ++ printInterval startTime' endTime'
        ++ " (synTime=" ++ printInterval startTime' synTime' ++ ")"
    (InSync (ae, ln), _) -> do
      -- Hell yeah, we can just broadcast. We don't care about the Broadcast control if we know we can broadcast.
      -- This saves us a lot of time when node count grows.
      pubRPC $ ae
      endTime' <- liftIO $ getCurrentTime
      debug $ "followers are in sync, pub AE with " ++ show ln ++ " log entries: " ++ printInterval startTime' endTime'
        ++ " (synTime=" ++ printInterval startTime' synTime' ++ ")"

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
--      debug $ "InfoAndEntriesAfter InSync " ++ (show (Just $ 1 + mni)) ++ " " ++ show limit'
--            ++ " with results " ++ show (Log.lesMinIndex es, Log.lesMaxIndex es)
      return $ InSync (AE' $ AppendEntries ct myNodeId' pli plt es Set.empty NewMsg, Log.lesCnt es)
    else do
      limit' <- view aeReplicationLogLimit
      mv <- queryLogs $ Set.singleton $ Log.GetInfoAndEntriesAfter (Just $ 1 + latestFollower) limit'
      (pli,plt, es) <- return $ Log.hasQueryResult (Log.InfoAndEntriesAfter (Just $ 1 + latestFollower) limit') mv
--      debug $ "InfoAndEntriesAfter Backstreet " ++ (show (Just $ 1 + latestFollower)) ++ " " ++ show limit'
--            ++ " with results " ++ show (Log.lesMinIndex es, Log.lesMaxIndex es)
      inSyncRpc <- return $! AE' $ AppendEntries ct myNodeId' pli plt es Set.empty NewMsg
      if everyoneBelieves
      then return $ BackStreet (inSyncRpc, laggingFollowers)
      else do
        oNodes' <- view otherNodes
        debug $ "non-believers exist, establishing dominance over " ++ show ((Set.size vts) - 1)
        return $ BackStreet (inSyncRpc, Set.union laggingFollowers (oNodes' Set.\\ vts))
{-# INLINE canBroadcastAE #-}

createAppendEntriesResponse' :: Bool -> Bool -> Term -> NodeId -> LogIndex -> Hash -> RPC
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

sendAllAppendEntriesResponse' :: Maybe UTCTime -> UTCTime -> LogIndex -> Hash -> SenderService ()
sendAllAppendEntriesResponse' issueTime stTime maxIndex' lastLogHash' = do
  ct <- view currentTerm
  myNodeId' <- view myNodeId
  aer <- return $ createAppendEntriesResponse' True True ct myNodeId' maxIndex' lastLogHash'
  pubRPC aer
  edTime <- liftIO $ getCurrentTime
  case issueTime of
    Nothing -> debug $ "pub AER taking " ++ show (interval stTime edTime) ++ "mics to construct"
    Just issueTime' -> debug $ "pub AER taking " ++ printInterval stTime edTime
                                ++ "(issueTime=" ++ printInterval issueTime' edTime ++ ")"

-- this is used for distributed evidence + updating the Leader with nodeCurrentIndex
sendAllAppendEntriesResponse :: SenderService ()
sendAllAppendEntriesResponse = do
  stTime <- liftIO $ getCurrentTime
  mv <- queryLogs $ Set.fromList [Log.GetMaxIndex, Log.GetLastLogHash]
  maxIndex' <- return $ Log.hasQueryResult Log.MaxIndex mv
  lastLogHash' <- return $ Log.hasQueryResult Log.LastLogHash mv
  sendAllAppendEntriesResponse' Nothing stTime maxIndex' lastLogHash'

sendRequestVoteResponse :: NodeId -> Maybe HeardFromLeader -> Bool -> SenderService ()
sendRequestVoteResponse target heardFromLeader vote = do
  term' <- view currentTerm
  myNodeId' <- view myNodeId
  pubRPC $! RVR' $! RequestVoteResponse term' heardFromLeader myNodeId' vote target NewMsg

pubRPC :: RPC -> SenderService ()
pubRPC rpc = do
  oChan <- view outboundGeneral
  myNodeId' <- view myNodeId
  privKey <- view myPrivateKey
  pubKey <- view myPublicKey
  sRpc <- return $ rpcToSignedRPC myNodeId' pubKey privKey rpc
  debug $ "broadcast msg sent: "
        ++ show (_digType $ _sigDigest sRpc)
        ++ (case rpc of
              AER' v -> " for " ++ show (_aerIndex v, _aerTerm v)
              RV' v -> " for " ++ show (_rvTerm v, _rvLastLogIndex v)
              RVR' v -> " for " ++ show (_rvrTerm v, _voteGranted v)
              _ -> "")
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
