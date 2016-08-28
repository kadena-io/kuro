{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types #-}

module Kadena.Consensus.Handle.Types (
    NodeId(..)
  , CommandEntry(..)
  , CommandResult(..)
  , Term(..), startTerm
  , LogIndex(..), startIndex
  , RequestId(..), startRequestId, toRequestId
  , Role(..)
  , LogEntry(..)
  -- * RPC
  , AppendEntries(..)
  , AppendEntriesResponse(..)
  , RequestVote(..)
  , RequestVoteResponse(..)
  , Command(..)
  , CommandResponse(..)
  , CommandBatch(..)
  , Revolution(..)
  , RPC(..)
  , Event(..)
  , MsgType(..), KeySet(..), Digest(..), Provenance(..), WireFormat(..)
  , signedRPCtoRPC, rpcToSignedRPC, verifySignedRPC
  , SignedRPC(..)
  , PrivateKey, PublicKey, Signature(..)
  , ReceivedAt(..)
  , LogEntries(..)
  , ReplicateLogEntries(..), rleMinLogIdx, rleMaxLogIdx, rlePrvLogIdx, rleEntries
  , toReplicateLogEntries
  , NewLogEntries(..), nleTerm, nleEntries
  , UpdateCommitIndex(..), uci
  , UpdateLogs(..)
  ) where

-- This module exists so we don't need to do a bunch of selective/hiding imports

import Kadena.Types
