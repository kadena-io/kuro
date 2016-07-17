{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Juno.Consensus.Client
  ( runRaftClient
  , clientSendRPC
  ) where

import Control.Concurrent (MVar, modifyMVar_, readMVar, newEmptyMVar, tryTakeMVar)
import qualified Control.Concurrent.Lifted as CL
import Control.Lens hiding (Index)
import Control.Monad.RWS

import Data.Foldable (traverse_)
import Data.IORef
import Data.Serialize
import Text.Read (readMaybe)
import qualified Data.ByteString.Char8 as SB8
import qualified Data.Map as Map
import qualified Data.Set as Set

import Data.Thyme.Clock (UTCTime)

import Juno.Runtime.MessageReceiver
import Juno.Runtime.Timer
import Juno.Types
import Juno.Util.Util

-- main entry point wired up by Simple.hs
-- getEntry (readChan) useResult (writeChan) replace by
-- CommandMVarMap (MVar shared with App client)
runRaftClient :: ReceiverEnv
              -> IO (RequestId, [(Maybe Alias,CommandEntry)])
              -> CommandMVarMap
              -> Config
              -> RaftSpec
              -> MVar Bool
              -> IO UTCTime
              -> IO ()
runRaftClient renv getEntries cmdStatusMap' rconf spec@RaftSpec{..} disableTimeouts timeCache' = do
  let csize = Set.size $ rconf ^. otherNodes
      qsize = getQuorumSize csize
  -- TODO: do we really need currentRequestId in state any longer, doing this to keep them in sync
  (CommandMap rid _) <- readMVar cmdStatusMap'
  void $ runMessageReceiver renv -- THREAD: CLIENT MESSAGE RECEIVER
  rconf' <- newIORef rconf
  timerTarget' <- newEmptyMVar
  mEvState <- newEmptyMVar
  mLeaderNoFollowers <- newEmptyMVar
  runRWS_
    (raftClient (lift getEntries) cmdStatusMap' disableTimeouts)
    (mkRaftEnv rconf' csize qsize spec (_dispatch renv) timerTarget' timeCache' mEvState mLeaderNoFollowers)
    -- TODO: because UTC can flow backwards, this request ID is problematic:
    (initialRaftState timerTarget') {_currentRequestId = rid} -- only use currentLeader and logEntries

-- TODO: don't run in raft, own monad stack
-- StateT ClientState (ReaderT ClientEnv IO)
-- THREAD: CLIENT MAIN
raftClient :: Raft (RequestId, [(Maybe Alias, CommandEntry)]) -> CommandMVarMap -> MVar Bool -> Raft ()
raftClient getEntries cmdStatusMap' disableTimeouts = do
  nodes <- viewConfig otherNodes
  when (Set.null nodes) $ error "The client has no nodes to send requests to."
  setCurrentLeader $ Just $ Set.findMin nodes
  void $ CL.fork $ commandGetter getEntries cmdStatusMap' -- THREAD: CLIENT COMMAND REPL?
  pendingRequests .= Map.empty
  clientHandleEvents cmdStatusMap' disableTimeouts -- forever read chan loop

-- get commands with getEntry and put them on the event queue to be sent
-- THREAD: CLIENT COMMAND
commandGetter :: Raft (RequestId, [(Maybe Alias, CommandEntry)]) -> CommandMVarMap -> Raft ()
commandGetter getEntries cmdStatusMap' = do
  nid <- viewConfig nodeId
  forever $ do
    (rid@(RequestId _), cmdEntries) <- getEntries
    -- support for special REPL command "> batch test:5000", runs hardcoded batch job
    cmds' <- case cmdEntries of
               (alias,CommandEntry cmd):[]
                 | SB8.take 11 cmd == "batch test:" -> do
                     let missiles = take (batchSize cmd) $ repeat $ hardcodedTransfers nid alias
                     liftIO $ sequence $ missiles
               _ -> liftIO $ sequence $ fmap (nextRid nid) cmdEntries
    -- set current requestId in Raft to the value associated with this request.
    rid' <- setNextRequestId rid
    liftIO (modifyMVar_ cmdStatusMap' (\(CommandMap n m) -> return $ CommandMap n (Map.insert rid CmdAccepted m)))
    -- hack set the head to the org rid
    let cmds'' = case cmds' of
                   ((Command entry nid' _ alias' NewMsg):rest) -> (Command entry nid' rid' alias' NewMsg):rest
                   _ -> [] -- TODO: fix this
    enqueueEvent $ ERPC $ CMDB' $ CommandBatch cmds'' NewMsg
  where
    batchSize :: (Num c, Read c) => SB8.ByteString -> c
    batchSize cmd = maybe 500 id . readMaybe $ drop 11 $ SB8.unpack cmd

    nextRid :: NodeId -> (Maybe Alias,CommandEntry) -> IO Command
    nextRid nid (alias',entry) = do
      rid <- (setNextCmdRequestId cmdStatusMap')
      return (Command entry nid rid alias' NewMsg)

    hardcodedTransfers :: NodeId -> Maybe Alias -> IO Command
    hardcodedTransfers nid alias = nextRid nid (alias, transferCmdEntry)

    transferCmdEntry :: CommandEntry
    transferCmdEntry = (CommandEntry "transfer(Acct1->Acct2, 1 % 1)")

setNextRequestId :: RequestId -> Raft RequestId
setNextRequestId rid = do
  currentRequestId .= rid
  use currentRequestId

-- THREAD: CLIENT MAIN. updates state
clientHandleEvents :: CommandMVarMap -> MVar Bool -> Raft ()
clientHandleEvents cmdStatusMap' disableTimeouts = forever $ do
  timerTarget' <- use timerTarget
  -- we use the MVar to preempt a backlog of messages when under load. This happens during a large 'many test'
  tFired <- liftIO $ tryTakeMVar timerTarget'
  e <- case tFired of
    Nothing -> dequeueEvent
    Just v -> return v
  case e of
    ERPC (CMDB' cmdb)   -> clientSendCommandBatch cmdb disableTimeouts
    ERPC (CMD' cmd)     -> clientSendCommand cmd disableTimeouts -- these are commands coming from the commandGetter thread
    ERPC (CMDR' cmdr)   -> clientHandleCommandResponse cmdStatusMap' cmdr disableTimeouts
    HeartbeatTimeout _ -> do
      t <- liftIO $ readMVar disableTimeouts
      debug $ "[HB_TIMEOUT] caught heartbeat " ++ show t
      when (not t) $ do
        debug "caught a heartbeat"
        timeouts <- use numTimeouts
        if timeouts > 3
        then do
          debug "choosing a new leader and resending commands"
          setLeaderToNext
          debug $ "[HB_TIMEOUT] Changing Leader to next " ++ show t
          reqs <- use pendingRequests
          pendingRequests .= Map.empty -- this will reset the timer on resend
          traverse_ (`clientSendCommand` disableTimeouts) reqs
          numTimeouts += 1
        else resetHeartbeatTimer >> numTimeouts += 1
    _ -> return ()

-- THREAD: CLIENT MAIN. updates state
-- If the client doesn't know the leader? Then set leader to first node, the client will be updated with the real leaderId when it receives a command response.
setLeaderToFirst :: Raft ()
setLeaderToFirst = do
  nodes <- viewConfig otherNodes
  when (Set.null nodes) $ error "the client has no nodes to send requests to"
  setCurrentLeader $ Just $ Set.findMin nodes

-- THREAD: CLIENT MAIN. updates state.
setLeaderToNext :: Raft ()
setLeaderToNext = do
  mlid <- use currentLeader
  nodes <- viewConfig otherNodes
  case mlid of
    Just lid -> case Set.lookupGT lid nodes of
      Just nlid -> setCurrentLeader $ Just nlid
      Nothing   -> setLeaderToFirst
    Nothing -> setLeaderToFirst

-- THREAD: CLIENT MAIN. updates state
clientSendCommand :: Command -> MVar Bool -> Raft ()
clientSendCommand cmd@Command{..} disableTimeouts = do
  mlid <- use currentLeader
  disableTimeouts' <- liftIO $ readMVar disableTimeouts
  case mlid of
    Just lid -> do
      clientSendRPC lid $ CMD' cmd
      debug $ "Sending Msg to :" ++ show (unAlias $ _alias lid)
      prcount <- fmap Map.size (use pendingRequests)
      -- if this will be our only pending request, start the timer
      -- otherwise, it should already be running
      when (prcount == 0 && not disableTimeouts') resetHeartbeatTimer
      pendingRequests %= Map.insert _cmdRequestId cmd -- TODO should we update CommandMap here?
    Nothing  -> do
      setLeaderToFirst
      liftIO $ putStrLn "[SendCommand] Changing Leader to first"
      clientSendCommand cmd disableTimeouts

-- THREAD: CLIENT MAIN. updates state
clientSendCommandBatch :: CommandBatch -> MVar Bool -> Raft ()
clientSendCommandBatch cmdb@CommandBatch{..} disableTimeouts = do
  mlid <- use currentLeader
  disableTimeouts' <- liftIO $ readMVar disableTimeouts
  case mlid of
    Just lid -> do
      clientSendRPC lid $ CMDB' cmdb
      debug $ "Sending Msg to :" ++ show (unAlias $ _alias lid)
      prcount <- fmap Map.size (use pendingRequests)
      -- if this will be our only pending request, start the timer
      -- otherwise, it should already be running
      let lastCmd = last _cmdbBatch
      when (prcount == 0 && not disableTimeouts') resetHeartbeatTimer
      pendingRequests %= Map.insert (_cmdRequestId lastCmd) lastCmd -- TODO should we update CommandMap here?
    Nothing  -> do
      setLeaderToFirst
      liftIO $ putStrLn "[SendBatch] Changing Leader to first"
      clientSendCommandBatch cmdb disableTimeouts

-- THREAD: CLIENT MAIN. updates state
-- Command has been applied
clientHandleCommandResponse :: CommandMVarMap -> CommandResponse -> MVar Bool -> Raft ()
clientHandleCommandResponse cmdStatusMap' CommandResponse{..} disableTimeouts = do
  prs <- use pendingRequests
  cLeader <- use currentLeader
  disableTimeouts' <- liftIO $ readMVar disableTimeouts
  when (Map.member _cmdrRequestId prs) $ do
    case (disableTimeouts', cLeader == Just _cmdrLeaderId) of
      (True, False)  -> debug $ "Timeout is disabled but got a CMDR from: " ++ show (unAlias $ _alias _cmdrLeaderId)
      _              -> do
        setCurrentLeader (Just _cmdrLeaderId)
        debug $ "[CMDR] setting leader to " ++ show (unAlias $ _alias _cmdrLeaderId) ++ " sent from " ++ show (unAlias $ _alias $ _digNodeId $ _pDig $ _cmdrProvenance)
        pendingRequests %= Map.delete _cmdrRequestId
        -- cmdStatusMap shared with the client, client can poll this map to await applied result
        liftIO (modifyMVar_ cmdStatusMap' (\(CommandMap rid m) -> return $ CommandMap rid (Map.insert _cmdrRequestId (CmdApplied _cmdrResult _cmdrLatency) m)))
        numTimeouts .= 0
        prcount <- fmap Map.size (use pendingRequests)
        -- if we still have pending requests, reset the timer
        -- otherwise cancel it
        if prcount > 0
          then resetHeartbeatTimer
          else cancelTimer

clientSendRPC :: NodeId -> RPC -> Raft ()
clientSendRPC target rpc = do
  send <- view clientSendMsg
  myNodeId' <- viewConfig nodeId
  privKey <- viewConfig myPrivateKey
  pubKey <- viewConfig myPublicKey
  sRpc <- return $ rpcToSignedRPC myNodeId' pubKey privKey rpc
  debug $ "Issuing direct msg: " ++ show (_digType $ _sigDigest sRpc) ++ " to " ++ show (unAlias $ _alias target)
  liftIO $! send $! directMsg target $ encode $ sRpc
