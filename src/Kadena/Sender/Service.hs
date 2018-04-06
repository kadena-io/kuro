{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Sender.Service
  ( SenderService
  , ServiceEnv(..), debugPrint, serviceRequestChan, outboundGeneral
  , logService, getEvidenceState, publishMetric, aeReplicationLogLimit
  , runSenderService
  , createAppendEntriesResponse' -- we need this for AER Evidence
  , willBroadcastAE
  , module X --re-export the types to make things straight forward
  ) where

import Control.Lens
import Control.Concurrent
import Control.Parallel.Strategies

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.RWS.Lazy

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Serialize hiding (get, put)

import Data.Thyme.Clock (UTCTime, getCurrentTime)

import Kadena.Types.Message
import Kadena.Types.Metric (Metric)
import Kadena.Types.Config (GlobalConfigTMVar,Config(..),readCurrentConfig)
import Kadena.Types.Spec (PublishedConsensus)
import Kadena.Types.Dispatch (Dispatch(..))
import Kadena.Types.Base
import Kadena.Types.Log (LogEntries(..))
import qualified Kadena.Types.Log as Log
import qualified Kadena.Types.Dispatch as KD
import Kadena.Types.Event (pprintBeat)
import Kadena.Types.Comms

import qualified Kadena.Types.Spec as Spec

import Kadena.Log.Types (LogServiceChannel)
import qualified Kadena.Log.Types as Log
import Kadena.Evidence.Types hiding (Heart)

import Kadena.Sender.Types as X

data ServiceEnv = ServiceEnv
  { _debugPrint :: !(String -> IO ())
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

type SenderService s = RWST ServiceEnv () s IO

-- TODO use configUpdater to populate an MVar local to the RWST
-- vs hitting the TVar every time we need to send something (or have SenderService do this internally)
getStateSnapshot :: GlobalConfigTMVar -> MVar PublishedConsensus -> IO StateSnapshot
getStateSnapshot conf' pcons' = do
  conf <- readCurrentConfig conf'
  st <- readMVar pcons'
  return $! StateSnapshot
    { _snapNodeId = _nodeId conf
    , _snapNodeRole = st ^. Spec.pcRole
    , _snapOtherNodes = _otherNodes conf
    , _snapLeader = st ^. Spec.pcLeader
    , _snapTerm = st ^. Spec.pcTerm
    , _snapPublicKey = _myPublicKey conf
    , _snapPrivateKey = _myPrivateKey conf
    , _snapYesVotes = st ^. Spec.pcYesVotes
    }

runSenderService
  :: Dispatch
  -> GlobalConfigTMVar
  -> (String -> IO ())
  -> (Metric -> IO ())
  -> MVar PublishedEvidenceState
  -> MVar Spec.PublishedConsensus
  -> IO ()
runSenderService dispatch gcm debugFn publishMetric' mPubEvState mPubCons = do
  conf <- readCurrentConfig gcm
  s <- return $ StateSnapshot
    { _snapNodeId = _nodeId conf
    , _snapNodeRole = Follower
    , _snapOtherNodes = _otherNodes conf
    , _snapLeader = Nothing
    , _snapTerm = startTerm
    , _snapPublicKey = _myPublicKey conf
    , _snapPrivateKey = _myPrivateKey conf
    , _snapYesVotes = Set.empty
    }
  env <- return $ ServiceEnv
    { _debugPrint = debugFn
    , _aeReplicationLogLimit = _aeBatchSize conf
    -- Comm Channels
    , _serviceRequestChan = _senderService dispatch
    , _outboundGeneral = dispatch ^. KD.outboundGeneral
    -- Log Storage
    , _logService = dispatch ^. KD.logService
    , _getEvidenceState = readMVar mPubEvState
    , _publishMetric = publishMetric'
    , _config = gcm
    , _pubCons = mPubCons
    }
  void $ liftIO $ runRWST serviceRequests env s

snapshotStateExternal :: SenderService StateSnapshot ()
snapshotStateExternal = do
  mPubCons <- view pubCons
  conf <- view config
  snap <- liftIO $ getStateSnapshot conf mPubCons
  put snap
  return ()

serviceRequests :: SenderService StateSnapshot ()
serviceRequests = do
  rrc <- view serviceRequestChan
  debug "launch!"
  forever $ do
    sr <- liftIO $ readComm rrc
    case sr of
      SendAllAppendEntriesResponse{..} -> do
        snapshotStateExternal
        stTime <- liftIO $ getCurrentTime
        sendAllAppendEntriesResponse' (Just _srIssuedTime) stTime _srLastLogHash _srMaxIndex

      ForwardCommandToLeader{..} -> do
        snapshotStateExternal
        s <- get
        let ldr = view snapLeader s
        case ldr of
          Nothing -> debug $ "Leader is down, unable to forward commands. Dropping..."
          Just ldr' -> do
            debug $ "fowarding " ++ show (length $ _newCmd $ _srCommands) ++ "commands to leader"
            sendRPC ldr' $ NEW' _srCommands
      (ServiceRequest' ss m) -> do
        put ss
        case m of
          BroadcastAE{..} -> do
            evState <- view getEvidenceState >>= liftIO
            sendAllAppendEntries (_pesNodeStates evState) (_pesConvincedNodes evState) _srAeBoardcastControl
          EstablishDominance -> establishDominance
          SingleAER{..} -> sendAppendEntriesResponse _srFor _srSuccess _srConvinced
          BroadcastAER -> sendAllAppendEntriesResponse
          BroadcastRV rv -> sendAllRequestVotes rv
          BroadcastRVR{..} -> sendRequestVoteResponse _srCandidate _srHeardFromLeader _srVote
      Heart t -> liftIO (pprintBeat t) >>= debug

queryLogs :: Set Log.AtomicQuery -> SenderService StateSnapshot (Map Log.AtomicQuery Log.QueryResult)
queryLogs q = do
  ls <- view logService
  mv <- liftIO newEmptyMVar
  liftIO . writeComm ls $ Log.Query q mv
  liftIO $ takeMVar mv

debug :: String -> SenderService StateSnapshot ()
debug s = do
  dbg <- view debugPrint
  liftIO $ dbg $ "[Service|Sender] " ++ s

-- views state, but does not update
sendAllRequestVotes :: RequestVote -> SenderService StateSnapshot ()
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

establishDominance :: SenderService StateSnapshot ()
establishDominance = do
  debug "establishing general dominance"
  stTime <- liftIO $ getCurrentTime
  s <- get
  let ct = view snapTerm s
  let myNodeId' = view snapNodeId s
  let yesVotes' = view snapYesVotes s
  mv <- queryLogs $ Set.fromList [Log.GetMaxIndex, Log.GetLastLogTerm]
  pli <- return $! Log.hasQueryResult Log.MaxIndex mv
  plt <- return $! Log.hasQueryResult Log.LastLogTerm mv
  rpc <- return $! AE' $ AppendEntries ct myNodeId' pli plt Log.lesEmpty yesVotes' NewMsg
  edTime <- liftIO $ getCurrentTime
  pubRPC rpc
  debug $ "asserted dominance: " ++ show (interval stTime edTime) ++ "mics"

-- | Send all append entries is only needed in special circumstances. Either we have a Heartbeat event or we are getting a quick win in with CMD's
sendAllAppendEntries :: Map NodeId (LogIndex, UTCTime) -> Set NodeId -> AEBroadcastControl -> SenderService StateSnapshot ()
sendAllAppendEntries nodeCurrentIndex' nodesThatFollow' sendIfOutOfSync = do
  startTime' <- liftIO $ getCurrentTime
  s <- get
  let ct = view snapTerm s
  let myNodeId' = view snapNodeId s
  let yesVotes' = view snapYesVotes s
  let oNodes = view snapOtherNodes s
  limit' <- view aeReplicationLogLimit
  inSync' <- canBroadcastAE (length oNodes) nodeCurrentIndex' ct myNodeId' nodesThatFollow' sendIfOutOfSync
  synTime' <- liftIO $ getCurrentTime
  case inSync' of
    BackStreet{..} -> do
      case broadcastRPC of
        Just broadcastableRPC -> do -- NB: SendAERegardless gets you here
          -- We can't take the short cut but the AE (which is overloaded as a heartbeat grr...) still need to be sent
          -- This usually takes place when we hit a heartbeat timeout
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
          pubRPC broadcastableRPC -- TODO: this is terrible as laggers will need a pause to catch up correctly unless we have them cache future AE
        Nothing -> do -- NB: OnlySendIfInSync gets you here
          -- We can't just spam AE's to the followers because they can get clogged with overlapping/redundant AE's. This eventually trips an election.
          -- TODO: figure out how an out of date follower can precache LEs that it can't add to it's log yet (without tripping an election)
          debug $ "AE withheld, followers are out of sync (synTime=" ++ printInterval startTime' synTime' ++ ")"
--           endTime' <- liftIO $ getCurrentTime
--           debug $ "followers are out of sync, broadcasting AE anyway: " ++ printInterval startTime' endTime'
--             ++ " (synTime=" ++ printInterval startTime' synTime' ++ ")"
    InSync{..} -> do
      -- Hell yeah, we can just broadcast. We don't care about the Broadcast control if we know we can broadcast.
      -- This saves us a lot of time when node count grows.
      pubRPC $ broadcastableRPC
      endTime' <- liftIO $ getCurrentTime
      debug $ "AE broadcasted, followers are in sync" ++ printInterval startTime' endTime'
        ++ " (synTime=" ++ printInterval startTime' synTime' ++ ")"

data InSync =
  InSync { broadcastableRPC :: !RPC}
  | BackStreet
    { broadcastRPC :: !(Maybe RPC)
    , laggingFollowers :: !(Set NodeId) }
  deriving (Show, Eq)

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
               -> AEBroadcastControl
               -> SenderService StateSnapshot InSync
canBroadcastAE clusterSize' nodeCurrentIndex' ct myNodeId' vts broadcastControl =
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
      return $ InSync $ AE' $ AppendEntries ct myNodeId' pli plt es Set.empty NewMsg
    else do
      inSyncRpc <- case broadcastControl of
        OnlySendIfFollowersAreInSync -> return Nothing
        SendAERegardless -> do
          limit' <- view aeReplicationLogLimit
          mv <- queryLogs $ Set.singleton $ Log.GetInfoAndEntriesAfter (Just $ 1 + latestFollower) limit'
          (pli,plt, es) <- return $ Log.hasQueryResult (Log.InfoAndEntriesAfter (Just $ 1 + latestFollower) limit') mv
--        debug $ "InfoAndEntriesAfter Backstreet " ++ (show (Just $ 1 + latestFollower)) ++ " " ++ show limit'
--              ++ " with results " ++ show (Log.lesMinIndex es, Log.lesMaxIndex es)
          return $! Just $! AE' $ AppendEntries ct myNodeId' pli plt es Set.empty NewMsg
      if everyoneBelieves
      then return $ BackStreet inSyncRpc laggingFollowers
      else do
        s <- get
        let oNodes' = view snapOtherNodes s
        debug $ "non-believers exist, establishing dominance over " ++ show ((Set.size vts) - 1)
        return $ BackStreet inSyncRpc $ Set.union laggingFollowers (oNodes' Set.\\ vts)
{-# INLINE canBroadcastAE #-}

createAppendEntriesResponse' :: Bool -> Bool -> Term -> NodeId -> LogIndex -> Hash -> RPC
createAppendEntriesResponse' success convinced ct myNodeId' lindex lhash =
  AER' $ AppendEntriesResponse ct myNodeId' success convinced lindex lhash NewMsg

-- this only gets used when a Follower is replying in the negative to the Leader
sendAppendEntriesResponse :: NodeId -> Bool -> Bool -> SenderService StateSnapshot ()
sendAppendEntriesResponse target success convinced = do
  s <- get
  let ct = view snapTerm s
  let myNodeId' = view snapNodeId s
  mv <- queryLogs $ Set.fromList [Log.GetMaxIndex, Log.GetLastLogHash]
  maxIndex' <- return $ Log.hasQueryResult Log.MaxIndex mv
  lastLogHash' <- return $ Log.hasQueryResult Log.LastLogHash mv
  sendRPC target $ createAppendEntriesResponse' success convinced ct myNodeId' maxIndex' lastLogHash'
  debug $ "sent AppendEntriesResponse: " ++ show ct

sendAllAppendEntriesResponse' :: Maybe UTCTime -> UTCTime -> LogIndex -> Hash -> SenderService StateSnapshot ()
sendAllAppendEntriesResponse' issueTime stTime maxIndex' lastLogHash' = do
  s <- get
  let ct = view snapTerm s
  let myNodeId' = view snapNodeId s
  aer <- return $ createAppendEntriesResponse' True True ct myNodeId' maxIndex' lastLogHash'
  pubRPC aer
  edTime <- liftIO $ getCurrentTime
  case issueTime of
    Nothing -> debug $ "pub AER taking " ++ show (interval stTime edTime) ++ "mics to construct"
    Just issueTime' -> debug $ "pub AER taking " ++ printInterval stTime edTime
                                ++ "(issueTime=" ++ printInterval issueTime' edTime ++ ")"

-- this is used for distributed evidence + updating the Leader with nodeCurrentIndex
sendAllAppendEntriesResponse :: SenderService StateSnapshot ()
sendAllAppendEntriesResponse = do
  stTime <- liftIO $ getCurrentTime
  mv <- queryLogs $ Set.fromList [Log.GetMaxIndex, Log.GetLastLogHash]
  maxIndex' <- return $ Log.hasQueryResult Log.MaxIndex mv
  lastLogHash' <- return $ Log.hasQueryResult Log.LastLogHash mv
  sendAllAppendEntriesResponse' Nothing stTime maxIndex' lastLogHash'

sendRequestVoteResponse :: NodeId -> Maybe HeardFromLeader -> Bool -> SenderService StateSnapshot ()
sendRequestVoteResponse target heardFromLeader vote = do
  s <- get
  let term' = view snapTerm s
  let myNodeId' = view snapNodeId s
  pubRPC $! RVR' $! RequestVoteResponse term' heardFromLeader myNodeId' vote target NewMsg

pubRPC :: RPC -> SenderService StateSnapshot ()
pubRPC rpc = do
  oChan <- view outboundGeneral
  s <- get
  let myNodeId' = view snapNodeId s
  let privKey = view snapPrivateKey s
  let pubKey = view snapPublicKey s
  sRpc <- return $ rpcToSignedRPC myNodeId' pubKey privKey rpc
  debug $ "broadcast msg sent: "
        ++ show (_digType $ _sigDigest sRpc)
        ++ (case rpc of
              AER' v -> " for " ++ show (_aerIndex v, _aerTerm v)
              RV' v -> " for " ++ show (_rvTerm v, _rvLastLogIndex v)
              RVR' v -> " for " ++ show (_rvrTerm v, _voteGranted v)
              _ -> "")
  liftIO $ writeComm oChan $ broadcastMsg [encode $ sRpc]

sendRPC :: NodeId -> RPC -> SenderService StateSnapshot ()
sendRPC target rpc = do
  oChan <- view outboundGeneral
  s <- get
  let myNodeId' = view snapNodeId s
  let privKey = view snapPrivateKey s
  let pubKey = view snapPublicKey s
  sRpc <- return $ rpcToSignedRPC myNodeId' pubKey privKey rpc
  debug $ "issuing direct msg: " ++ show (_digType $ _sigDigest sRpc) ++ " to " ++ show (unAlias $ _alias target)
  liftIO $! writeComm oChan $! directMsg [(target, encode $ sRpc)]

sendRpcsPeicewise :: [(NodeId, RPC)] -> (Int, UTCTime) -> SenderService StateSnapshot ()
sendRpcsPeicewise rpcs d@(total, stTime) = do
  (aFewRpcs,rest) <- return $! splitAt 8 rpcs
  if null rest
  then do
    sendRPCs aFewRpcs
    edTime <- liftIO $ getCurrentTime
    debug $ "Sent " ++ show total ++ " RPCs taking " ++ show (interval stTime edTime) ++ "mics to construct"
  else sendRpcsPeicewise rest d

sendRPCs :: [(NodeId, RPC)] -> SenderService StateSnapshot ()
sendRPCs rpcs = do
  oChan <- view outboundGeneral
  s <- get
  let myNodeId' = view snapNodeId s
  let privKey = view snapPrivateKey s
  let pubKey = view snapPublicKey s
  msgs <- return (((\(n,msg) -> (n, encode $ rpcToSignedRPC myNodeId' pubKey privKey msg)) <$> rpcs) `using` parList rseq)
  liftIO $ writeComm oChan $! directMsg msgs
