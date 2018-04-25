{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Log
  ( LogEntry(..), leTerm, leLogIndex, leCommand, leHash, leCmdLatMetrics
  , LogEntries(..), logEntries
  , PersistedLogEntries(..), pLogEntries
  , LEWire(..)
  , ReplicateLogEntries(..), rleMinLogIdx, rleMaxLogIdx, rlePrvLogIdx, rleEntries
  , VerifiedLogEntries(..)
  , NewLogEntries(..), nleTerm, nleEntries
  , UpdateCommitIndex(..), uci, uciTimeStamp
  , UpdateLogs(..)
  , AtomicQuery(..)
  , FirstEntry(..), LastEntry(..), MaxIndex(..), EntryCount(..), SomeEntry(..)
  , LogInfoForNextIndex(..) , LastLogHash(..), LastLogTerm(..)
  , EntriesAfter(..), InfoAndEntriesAfter(..)
  , LastApplied(..), LastLogIndex(..), NextLogIndex(..), CommitIndex(..)
  , UnappliedEntries(..)
  , QueryResult(..)
  , HasQueryResult(..)
  , NleEntries(..)
  ) where

import Control.Lens hiding (Index, (|>))

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.IntMap.Strict (IntMap)

import Data.Serialize hiding (get)

import Data.Thyme.Time.Core ()
import Data.Thyme.Clock
import GHC.Generics

import Kadena.Types.Base
import Kadena.Types.Command
 
-- TODO: add discrimination here, so we can get a better map construction
data LogEntry = LogEntry
  { _leTerm     :: !Term
  , _leLogIndex :: !LogIndex
  , _leCommand  :: !Command
  , _leHash     :: !Hash
  , _leCmdLatMetrics :: !(Maybe CmdLatencyMetrics)
  }
  deriving (Show, Eq, Ord, Generic)
makeLenses ''LogEntry

data LEWire = LEWire (Term, LogIndex, CMDWire, Hash)
  deriving (Show, Generic)
instance Serialize LEWire

newtype LogEntries = LogEntries { _logEntries :: Map LogIndex LogEntry }
    deriving (Eq,Show,Ord,Generic)
makeLenses ''LogEntries 

newtype PersistedLogEntries = PersistedLogEntries { _pLogEntries :: Map LogIndex LogEntries }
    deriving (Eq,Show,Ord,Generic)
makeLenses ''PersistedLogEntries

newtype VerifiedLogEntries = VerifiedLogEntries
  { _vleResults :: IntMap Command}
  deriving (Show, Eq)

data ReplicateLogEntries = ReplicateLogEntries
  { _rleMinLogIdx :: LogIndex
  , _rleMaxLogIdx :: LogIndex
  , _rlePrvLogIdx :: LogIndex
  , _rleEntries   :: LogEntries
  } deriving (Show, Eq, Generic)
makeLenses ''ReplicateLogEntries 

newtype NleEntries = NleEntries { unNleEntries :: [(Maybe CmdLatencyMetrics, Command)] } deriving (Eq,Show)

data NewLogEntries = NewLogEntries
  { _nleTerm :: !Term
  , _nleEntries :: !NleEntries
  } deriving (Show, Eq, Generic)
makeLenses ''NewLogEntries

data UpdateCommitIndex = UpdateCommitIndex
  { _uci :: !LogIndex
  , _uciTimeStamp :: !UTCTime }
  deriving (Show, Eq, Generic)
makeLenses ''UpdateCommitIndex

data UpdateLogs =
  ULReplicate ReplicateLogEntries |
  ULNew NewLogEntries |
  ULCommitIdx UpdateCommitIndex |
  UpdateLastApplied LogIndex
  deriving (Show, Eq, Generic)

data AtomicQuery =
  GetFirstEntry |
  GetLastEntry |
  GetMaxIndex |
  GetEntryCount |
  GetSomeEntry LogIndex |
  GetUnappliedEntries |
  GetLogInfoForNextIndex (Maybe LogIndex) |
  GetLastLogHash |
  GetLastLogTerm |
  GetEntriesAfter LogIndex Int |
  GetInfoAndEntriesAfter (Maybe LogIndex) Int |
  GetLastApplied |
  GetLastLogIndex |
  GetNextLogIndex |
  GetCommitIndex
  deriving (Eq, Ord, Show)

data QueryResult =
  QrFirstEntry (Maybe LogEntry) |
  QrLastEntry (Maybe LogEntry) |
  QrMaxIndex LogIndex |
  QrEntryCount Int |
  QrSomeEntry (Maybe LogEntry) |
  QrUnappliedEntries (Maybe LogEntries) |
  QrLogInfoForNextIndex (LogIndex,Term) |
  QrLastLogHash Hash |
  QrLastLogTerm Term |
  QrEntriesAfter LogEntries |
  QrInfoAndEntriesAfter (LogIndex, Term, LogEntries) |
  QrLastApplied LogIndex |
  QrLastLogIndex LogIndex |
  QrNextLogIndex LogIndex |
  QrCommitIndex LogIndex
  deriving (Eq, Ord, Show)

data FirstEntry = FirstEntry deriving (Eq,Show)
data LastEntry = LastEntry deriving (Eq,Show)
data MaxIndex = MaxIndex deriving (Eq,Show)
data EntryCount = EntryCount deriving (Eq,Show)
data SomeEntry = SomeEntry LogIndex deriving (Eq,Show)
data UnappliedEntries = UnappliedEntries deriving (Eq,Show)
data LogInfoForNextIndex = LogInfoForNextIndex (Maybe LogIndex) deriving (Eq,Show)
data LastLogHash = LastLogHash deriving (Eq,Show)
data LastLogTerm = LastLogTerm deriving (Eq,Show)
data EntriesAfter = EntriesAfter LogIndex Int deriving (Eq,Show)
data InfoAndEntriesAfter = InfoAndEntriesAfter (Maybe LogIndex) Int deriving (Eq,Show)
data LastApplied = LastApplied deriving (Eq,Show)
data LastLogIndex = LastLogIndex deriving (Eq,Show)
data NextLogIndex = NextLogIndex deriving (Eq,Show)
data CommitIndex = CommitIndex deriving (Eq,Show)

class HasQueryResult a b | a -> b where
  hasQueryResult :: a -> Map AtomicQuery QueryResult -> b

instance HasQueryResult LastApplied LogIndex where
  hasQueryResult LastApplied m = case Map.lookup GetLastApplied m of
    Just (QrLastApplied v)  -> v
    _ -> error "Invariant Error: hasQueryResult LastApplied failed to find LastApplied"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult LastLogIndex LogIndex where
  hasQueryResult LastLogIndex m = case Map.lookup GetLastLogIndex m of
    Just (QrLastLogIndex v)  -> v
    _ -> error "Invariant Error: hasQueryResult LastLogIndex failed to find LastLogIndex"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult NextLogIndex LogIndex where
  hasQueryResult NextLogIndex m = case Map.lookup GetNextLogIndex m of
    Just (QrNextLogIndex v)  -> v
    _ -> error "Invariant Error: hasQueryResult NextLogIndex failed to find NextLogIndex"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult CommitIndex LogIndex where
  hasQueryResult CommitIndex m = case Map.lookup GetCommitIndex m of
    Just (QrCommitIndex v)  -> v
    _ -> error "Invariant Error: hasQueryResult CommitIndex failed to find CommitIndex"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult FirstEntry (Maybe LogEntry) where
  hasQueryResult FirstEntry m = case Map.lookup GetFirstEntry m of
    Just (QrFirstEntry v)  -> v
    _ -> error "Invariant Error: hasQueryResult FirstEntry failed to find FirstEntry"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult LastEntry (Maybe LogEntry) where
  hasQueryResult LastEntry m = case Map.lookup GetLastEntry m of
    Just (QrLastEntry v) -> v
    _ -> error "Invariant Error: hasQueryResult LastEntry failed to find LastEntry"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult MaxIndex LogIndex where
  hasQueryResult MaxIndex m = case Map.lookup GetMaxIndex m of
    Just (QrMaxIndex v) -> v
    _ -> error "Invariant Error: hasQueryResult MaxIndex failed to find MaxIndex"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult EntryCount Int where
  hasQueryResult EntryCount m = case Map.lookup GetEntryCount m of
    Just (QrEntryCount v) -> v
    _ -> error "Invariant Error: hasQueryResult EntryCount failed to find EntryCount"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult SomeEntry (Maybe LogEntry) where
  hasQueryResult (SomeEntry li) m = case Map.lookup (GetSomeEntry li) m of
    Just (QrSomeEntry v) -> v
    _ -> error "Invariant Error: hasQueryResult SomeEntry failed to find SomeEntry"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult UnappliedEntries (Maybe LogEntries) where
  hasQueryResult UnappliedEntries m = case Map.lookup GetUnappliedEntries m of
    Just (QrUnappliedEntries v) -> v
    _ -> error "Invariant Error: hasQueryResult TakenEntries failed to find TakenEntries"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult LogInfoForNextIndex (LogIndex,Term) where
  hasQueryResult (LogInfoForNextIndex mli) m = case Map.lookup (GetLogInfoForNextIndex mli) m of
    Just (QrLogInfoForNextIndex v) -> v
    _ -> error "Invariant Error: hasQueryResult LogInfoForNextIndex failed to find LogInfoForNextIndex"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult LastLogHash Hash where
  hasQueryResult LastLogHash m = case Map.lookup GetLastLogHash m of
    Just (QrLastLogHash v) -> v
    _ -> error "Invariant Error: hasQueryResult LastLogHash failed to find LastLogHash"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult LastLogTerm Term where
  hasQueryResult LastLogTerm m = case Map.lookup GetLastLogTerm m of
    Just (QrLastLogTerm v) -> v
    _ -> error "Invariant Error: hasQueryResult LastLogTerm failed to find LastLogTerm"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult EntriesAfter LogEntries where
  hasQueryResult (EntriesAfter li cnt) m = case Map.lookup (GetEntriesAfter li cnt) m of
    Just (QrEntriesAfter v) -> v
    _ -> error "Invariant Error: hasQueryResult EntriesAfter failed to find EntriesAfter"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult InfoAndEntriesAfter (LogIndex, Term, LogEntries) where
  hasQueryResult (InfoAndEntriesAfter mli cnt) m = case Map.lookup (GetInfoAndEntriesAfter mli cnt) m of
    Just (QrInfoAndEntriesAfter v) -> v
    _ -> error "Invariant Error: hasQueryResult InfoAndEntriesAfter failed to find InfoAndEntriesAfter"
  {-# INLINE hasQueryResult #-}
