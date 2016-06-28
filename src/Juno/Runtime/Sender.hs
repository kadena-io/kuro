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
  ) where

import Control.Lens
import Control.Arrow (second)
import Control.Parallel.Strategies
import Control.Monad.Writer

import Data.ByteString (ByteString)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Serialize

import Juno.Util.Util
import Juno.Types
import Juno.Runtime.Timer (resetLastBatchUpdate)

createAppendEntries' :: NodeId
                   -> Map NodeId LogIndex
                   -> Log LogEntry
                   -> Term
                   -> NodeId
                   -> Set NodeId
                   -> Set RequestVoteResponse
                   -> RPC
createAppendEntries' target lNextIndex' es ct nid vts yesVotes =
  let
    mni = Map.lookup target lNextIndex'
    (pli,plt) = logInfoForNextIndex mni es
    vts' = if Set.member target vts then Set.empty else yesVotes
  in
    AE' $ AppendEntries ct nid pli plt (getEntriesAfter pli es) vts' NewMsg

sendAppendEntries :: NodeId -> Raft ()
sendAppendEntries target = do
  lNextIndex' <- use lNextIndex
  es <- use logEntries
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
  es <- use logEntries
  ct <- use term
  nid <- viewConfig nodeId
  vts <- use lConvinced
  yesVotes <- use cYesVotes
  oNodes <- viewConfig otherNodes
  sendRPCs $ (\target -> (target, createAppendEntries' target lNextIndex' es ct nid vts yesVotes)) <$> Set.toList oNodes
  resetLastBatchUpdate
  debug "Sent All AppendEntries"

createAppendEntriesResponse' :: Bool -> Bool -> Term -> NodeId -> LogIndex -> ByteString -> RPC
createAppendEntriesResponse' success convinced ct nid lindex lhash =
  AER' $ AppendEntriesResponse ct nid success convinced lindex lhash True NewMsg

createAppendEntriesResponse :: Bool -> Bool -> Raft AppendEntriesResponse
createAppendEntriesResponse success convinced = do
  ct <- use term
  nid <- viewConfig nodeId
  es <- use logEntries
  case createAppendEntriesResponse' success convinced ct nid
           (maxIndex es) (lastLogHash es) of
    AER' aer -> return aer
    _ -> error "deep invariant error"

sendAppendEntriesResponse :: NodeId -> Bool -> Bool -> Raft ()
sendAppendEntriesResponse target success convinced = do
  ct <- use term
  nid <- viewConfig nodeId
  es <- use logEntries
  sendRPC target $ createAppendEntriesResponse' success convinced ct nid
              (maxIndex es) (lastLogHash es)
  debug $ "Sent AppendEntriesResponse: " ++ show ct

sendAllAppendEntriesResponse :: Raft ()
sendAllAppendEntriesResponse = do
  ct <- use term
  nid <- viewConfig nodeId
  es <- use logEntries
  aer <- return $ createAppendEntriesResponse' True True ct nid (maxIndex es) (lastLogHash es)
  oNodes <- viewConfig otherNodes
  sendRPCs $ (,aer) <$> Set.toList oNodes

createRequestVoteResponse :: MonadWriter [String] m => Term -> LogIndex -> NodeId -> NodeId -> Bool -> m RequestVoteResponse
createRequestVoteResponse term' logIndex' myNodeId' target vote = do
  tell ["Created RequestVoteResponse: " ++ show term']
  return $ RequestVoteResponse term' logIndex' myNodeId' vote target NewMsg

sendResults :: [(NodeId, CommandResponse)] -> Raft ()
sendResults results = sendRPCs $ second CMDR' <$> results

sendRPC :: NodeId -> RPC -> Raft ()
sendRPC target rpc = do
  send <- view sendMessage
  myNodeId <- viewConfig nodeId
  privKey <- viewConfig myPrivateKey
  pubKey <- viewConfig myPublicKey
  liftIO $ send target $ encode $ rpcToSignedRPC myNodeId pubKey privKey rpc

encodedRPC :: NodeId -> PrivateKey -> PublicKey -> RPC -> ByteString
encodedRPC myNodeId privKey pubKey rpc = encode $! rpcToSignedRPC myNodeId pubKey privKey rpc
{-# INLINE encodedRPC #-}

sendRPCs :: [(NodeId, RPC)] -> Raft ()
sendRPCs rpcs = do
  send <- view sendMessages
  myNodeId <- viewConfig nodeId
  privKey <- viewConfig myPrivateKey
  pubKey <- viewConfig myPublicKey
  msgs <- return ((second (encodedRPC myNodeId privKey pubKey) <$> rpcs ) `using` parList rseq)
  liftIO $ send msgs
