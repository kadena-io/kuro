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

module Juno.Types.Service.Log
  ( LogState(..), lsLogEntries, lsLastApplied, lsLastLogIndex, lsNextLogIndex, lsCommitIndex
  , lsLastPersisted, lsLastLogTerm
  , LogApi(..)
  , initLogState
  , UpdateLogs(..)
  , AtomicQuery(..)
  , QueryResult(..)
  , QueryApi(..)
  , evalQuery
  , LogEnv(..), logQueryChannel, debugPrint, dbConn
  , HasQueryResult(..)
  , LogThread
  , LogServiceChannel(..)
  , FirstEntry(..), LastEntry(..), MaxIndex(..), EntryCount(..), SomeEntry(..)
  , TakenEntries(..), LogInfoForNextIndex(..) , LastLogHash(..), LastLogTerm(..)
  , EntriesAfter(..), InfoAndEntriesAfter(..)
  , LastApplied(..), LastLogIndex(..), NextLogIndex(..), CommitIndex(..)
  , UnappliedEntries(..)
  , module X
  ) where


import Control.Lens hiding (Index, (|>))

import Control.Concurrent (MVar)
import qualified Control.Concurrent.Chan.Unagi as Unagi
import Control.Monad.Trans.RWS.Strict

import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Serialize hiding (get)

import Database.SQLite.Simple (Connection(..))

import GHC.Generics

import Juno.Types.Base
import Juno.Types.Log
import qualified Juno.Types.Log as X
import Juno.Types.Comms
import Juno.Types.Message.Signed
import Juno.Types.Message.CMD

class LogApi a where
  lastPersisted :: a -> LogIndex
  lastApplied :: a -> LogIndex
  lastLogIndex :: a -> LogIndex
  nextLogIndex :: a -> LogIndex
  commitIndex :: a -> LogIndex
  -- | Get the first entry
  firstEntry :: a -> Maybe LogEntry
  -- | Get last entry.
  lastEntry :: a -> Maybe LogEntry
  -- | Get largest index in ledger.
  maxIndex :: a -> LogIndex
  -- | Get count of entries in ledger.
  entryCount :: a -> Int
  -- | Safe index
  lookupEntry :: LogIndex -> a -> Maybe LogEntry
  -- | Take operation: `takeEntries 3 $ Log $ Seq.fromList [0,1,2,3,4] == fromList [0,1,2]`
  takeEntries :: LogIndex -> a -> (Maybe (Seq LogEntry))
  -- | called by leaders sending appendEntries.
  -- given a replica's nextIndex, get the index and term to send as
  -- prevLog(Index/Term)
  -- | get every entry that hasn't been applied yet (betweek LastApplied and CommitIndex)
  getUnappliedEntries :: a -> Maybe (Seq LogEntry)
  getUnpersisted      :: a -> Maybe (Seq LogEntry)
  logInfoForNextIndex :: Maybe LogIndex -> a -> (LogIndex,Term)
  -- | Latest hash or empty
  lastLogHash :: a -> ByteString
  -- | Latest term on log or 'startTerm'
  lastLogTerm :: a -> Term
  -- | get entries after index to beginning, with limit, for AppendEntries message.
  -- TODO make monadic to get 8000 limit from config.
  getEntriesAfter :: LogIndex -> Int -> a -> Seq LogEntry
  updateLogs :: UpdateLogs -> a -> a

data LogState a = LogState
  { _lsLogEntries       :: !(Log a)
  , _lsLastApplied      :: !LogIndex
  , _lsLastLogIndex     :: !LogIndex
  , _lsNextLogIndex     :: !LogIndex
  , _lsCommitIndex      :: !LogIndex
  , _lsLastPersisted    :: !LogIndex
  , _lsLastLogTerm      :: !Term
  } deriving (Show, Eq, Generic)
makeLenses ''LogState

viewLogSeq :: LogState LogEntry -> Seq LogEntry
viewLogSeq = view (lsLogEntries.lEntries)

viewLogs :: LogState LogEntry -> Log LogEntry
viewLogs = view lsLogEntries

initLogState :: LogState LogEntry
initLogState = LogState
  { _lsLogEntries = mempty
  , _lsLastApplied = startIndex
  , _lsLastLogIndex = startIndex
  , _lsNextLogIndex = startIndex + 1
  , _lsCommitIndex = startIndex
  , _lsLastPersisted = startIndex
  , _lsLastLogTerm = startTerm
  }

instance LogApi (LogState LogEntry) where
  lastPersisted a = view lsLastPersisted a
  {-# INLINE lastPersisted #-}

  lastApplied a = view lsLastApplied a
  {-# INLINE lastApplied #-}

  lastLogIndex a = view lsLastLogIndex a
  {-# INLINE lastLogIndex #-}

  nextLogIndex a = view lsNextLogIndex a
  {-# INLINE nextLogIndex #-}

  commitIndex a = view lsCommitIndex a
  {-# INLINE commitIndex #-}

  firstEntry ls = case viewLogs ls of
    (e :< _) -> Just e
    _        -> Nothing
  {-# INLINE firstEntry #-}

  lastEntry ls = case viewLogs ls of
    (_ :> e) -> Just e
    _        -> Nothing
  {-# INLINE lastEntry #-}

  maxIndex ls = maybe startIndex _leLogIndex (lastEntry ls)
  {-# INLINE maxIndex #-}

  entryCount ls = fromIntegral . Seq.length . viewLogSeq $ ls
  {-# INLINE entryCount #-}

  lookupEntry i = firstOf (ix i) . viewLogs
  {-# INLINE lookupEntry #-}

  takeEntries t ls = case Seq.take (fromIntegral t) $ viewLogSeq ls of
    v | Seq.null v -> Nothing
      | otherwise  -> Just v
  {-# INLINE takeEntries #-}

  getUnappliedEntries ls =
    let ci = commitIndex ls
        la = lastApplied ls
    in if la < ci
       then fmap (Seq.drop (fromIntegral $ la + 1)) $ takeEntries (ci + 1) ls
       else Nothing
  {-# INLINE getUnappliedEntries #-}

  getUnpersisted ls =
    let la = lastApplied ls
        lp = lastPersisted ls
    in if lp < la
       then fmap (Seq.drop (fromIntegral $ lp + 1)) $ takeEntries (la + 1) ls
       else Nothing
  {-# INLINE getUnpersisted #-}

  logInfoForNextIndex Nothing          _  = (startIndex, startTerm)
  logInfoForNextIndex (Just myNextIdx) ls = let pli = myNextIdx - 1 in
    case lookupEntry pli ls of
          Just LogEntry{..} -> (pli, _leTerm)
          -- this shouldn't happen, because nextIndex - 1 should always be at
          -- most our last entry
          Nothing -> (startIndex, startTerm)
  {-# INLINE logInfoForNextIndex #-}

  lastLogHash = maybe mempty _leHash . lastEntry
  {-# INLINE lastLogHash #-}

  lastLogTerm ls = view lsLastLogTerm ls
  {-# INLINE lastLogTerm #-}

  getEntriesAfter pli cnt = Seq.take cnt . Seq.drop (fromIntegral $ pli + 1) . viewLogSeq
  {-# INLINE getEntriesAfter #-}

  updateLogs (ULNew nle) ls = appendLogEntry nle ls
  updateLogs (ULReplicate ReplicateLogEntries{..}) ls = addLogEntriesAt _rlePrvLogIdx _rleEntries ls
  updateLogs (ULCommitIdx UpdateCommitIndex{..}) ls = ls {_lsCommitIndex = _uci}
  updateLogs (UpdateLastApplied li) ls = ls {_lsLastApplied = li}
  {-# INLINE updateLogs  #-}


addLogEntriesAt :: LogIndex -> Seq LogEntry -> LogState LogEntry -> LogState LogEntry
addLogEntriesAt pli newLEs ls =
  let ls' = updateLogHashesFromIndex (pli + 1)
                . over (lEntries) ((Seq.>< newLEs)
                . Seq.take (fromIntegral pli + 1))
                $ _lsLogEntries ls
      (lastIdx',lastTerm') = case ls' ^. lEntries of
        (_ :> e) -> (_leLogIndex e, _leTerm e)
        _        -> (ls ^. lsLastLogIndex, ls ^. lsLastLogTerm)
  in ls { _lsLogEntries = ls'
        , _lsLastLogIndex = lastIdx'
        , _lsNextLogIndex = lastIdx' + 1
        , _lsLastLogTerm = lastTerm'
        }
{-# INLINE addLogEntriesAt #-}

-- Since the only node to ever append a log entry is the Leader we can start keeping the logs in sync here
-- TODO: this needs to handle picking the right LogIndex
appendLogEntry :: NewLogEntries -> LogState LogEntry -> LogState LogEntry
appendLogEntry NewLogEntries{..} ls = case lastEntry ls of
    Just ple -> let
        nle = newEntriesToLog (_nleTerm) (_leHash ple) (ls ^. lsNextLogIndex) _nleEntries
        ls' = ls { _lsLogEntries = Log $ (Seq.><) (viewLogSeq ls) nle }
        lastIdx' = maybe (ls ^. lsLastLogIndex) _leLogIndex $ seqTail nle
        lastTerm' = maybe (ls ^. lsLastLogTerm) _leTerm $ seqTail nle
      in ls' { _lsLastLogIndex = lastIdx'
             , _lsNextLogIndex = lastIdx' + 1
             , _lsLastLogTerm  = lastTerm' }
    Nothing -> let
        nle = newEntriesToLog (_nleTerm) (B.empty) (ls ^. lsNextLogIndex) _nleEntries
        ls' = ls { _lsLogEntries = Log nle }
        lastIdx' = maybe (ls ^. lsLastLogIndex) _leLogIndex $ seqTail nle
        lastTerm' = maybe (ls ^. lsLastLogTerm) _leTerm $ seqTail nle
      in ls' { _lsLastLogIndex = lastIdx'
             , _lsNextLogIndex = lastIdx' + 1
             , _lsLastLogTerm  = lastTerm' }
{-# INLINE appendLogEntry #-}

newEntriesToLog :: Term -> ByteString -> LogIndex -> [Command] -> Seq LogEntry
newEntriesToLog ct prevHash idx cmds = Seq.fromList $ go prevHash idx cmds
  where
    go _ _ [] = []
    go prevHash' i [c] = [LogEntry ct i c (hashNewEntry prevHash' ct i c)]
    go prevHash' i (c:cs) = let
        newHash = hashNewEntry prevHash' ct i c
      in (LogEntry ct i c newHash) : go newHash (i + 1) cs
{-# INLINE newEntriesToLog #-}

updateLogHashesFromIndex :: LogIndex -> Log LogEntry -> Log LogEntry
updateLogHashesFromIndex i ls =
  case firstOf (ix i) ls of
    Just _ -> updateLogHashesFromIndex (succ i) $
              over (lEntries) (Seq.adjust (hashLogEntry (firstOf (ix (i - 1)) ls)) (fromIntegral i)) ls
    Nothing -> ls
{-# INLINE updateLogHashesFromIndex #-}

hashNewEntry :: ByteString -> Term -> LogIndex -> Command -> ByteString
hashNewEntry prevHash leTerm' leLogIndex' cmd = hash (encode $ LEWire (leTerm', leLogIndex', sigCmd cmd, prevHash))
  where
    sigCmd Command{ _cmdProvenance = ReceivedMsg{ _pDig = dig, _pOrig = bdy }} =
      SignedRPC dig bdy
    sigCmd Command{ _cmdProvenance = NewMsg } =
      error "Invariant Failure: for a command to be in a log entry, it needs to have been received!"
{-# INLINE hashNewEntry #-}

data AtomicQuery =
  GetFirstEntry |
  GetLastEntry |
  GetMaxIndex |
  GetEntryCount |
  GetSomeEntry LogIndex |
  TakeEntries LogIndex |
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
  QrTakenEntries (Maybe (Seq LogEntry)) |
  QrUnappliedEntries (Maybe (Seq LogEntry)) |
  QrLogInfoForNextIndex (LogIndex,Term) |
  QrLastLogHash ByteString |
  QrLastLogTerm Term |
  QrEntriesAfter (Seq LogEntry) |
  QrInfoAndEntriesAfter (LogIndex, Term, Seq LogEntry) |
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
data TakenEntries = TakenEntries LogIndex deriving (Eq,Show)
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

evalQuery :: LogApi a => AtomicQuery -> a -> QueryResult
evalQuery GetLastApplied a = QrLastApplied $! lastApplied a
evalQuery GetLastLogIndex a = QrLastLogIndex $! lastLogIndex a
evalQuery GetNextLogIndex a = QrNextLogIndex $! nextLogIndex a
evalQuery GetCommitIndex a = QrCommitIndex $! commitIndex a
evalQuery GetFirstEntry a = QrFirstEntry $! firstEntry a
evalQuery GetLastEntry a = QrLastEntry $! lastEntry a
evalQuery GetMaxIndex a = QrMaxIndex $! maxIndex a
evalQuery GetUnappliedEntries a = QrUnappliedEntries $! getUnappliedEntries a
evalQuery GetEntryCount a = QrEntryCount $! entryCount a
evalQuery (GetSomeEntry li) a = QrSomeEntry $! lookupEntry li a
evalQuery (TakeEntries li) a = QrTakenEntries $! takeEntries li a
evalQuery (GetLogInfoForNextIndex mli) a = QrLogInfoForNextIndex $! logInfoForNextIndex mli a
evalQuery GetLastLogHash a = QrLastLogHash $! lastLogHash a
evalQuery GetLastLogTerm a = QrLastLogTerm $! lastLogTerm a
evalQuery (GetEntriesAfter li cnt) a = QrEntriesAfter $! getEntriesAfter li cnt a
evalQuery (GetInfoAndEntriesAfter mli cnt) a =
  let (pli, plt) = logInfoForNextIndex mli a
      es = getEntriesAfter pli cnt a
  in QrInfoAndEntriesAfter $! (pli, plt, es)
{-# INLINE evalQuery #-}

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

instance HasQueryResult UnappliedEntries (Maybe (Seq LogEntry)) where
  hasQueryResult UnappliedEntries m = case Map.lookup GetUnappliedEntries m of
    Just (QrUnappliedEntries v) -> v
    _ -> error "Invariant Error: hasQueryResult TakenEntries failed to find TakenEntries"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult TakenEntries (Maybe (Seq LogEntry)) where
  hasQueryResult (TakenEntries li) m = case Map.lookup (TakeEntries li) m of
    Just (QrTakenEntries v) -> v
    _ -> error "Invariant Error: hasQueryResult TakenEntries failed to find TakenEntries"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult LogInfoForNextIndex (LogIndex,Term) where
  hasQueryResult (LogInfoForNextIndex mli) m = case Map.lookup (GetLogInfoForNextIndex mli) m of
    Just (QrLogInfoForNextIndex v) -> v
    _ -> error "Invariant Error: hasQueryResult LogInfoForNextIndex failed to find LogInfoForNextIndex"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult LastLogHash ByteString where
  hasQueryResult LastLogHash m = case Map.lookup GetLastLogHash m of
    Just (QrLastLogHash v) -> v
    _ -> error "Invariant Error: hasQueryResult LastLogHash failed to find LastLogHash"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult LastLogTerm Term where
  hasQueryResult LastLogTerm m = case Map.lookup GetLastLogTerm m of
    Just (QrLastLogTerm v) -> v
    _ -> error "Invariant Error: hasQueryResult LastLogTerm failed to find LastLogTerm"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult EntriesAfter (Seq LogEntry) where
  hasQueryResult (EntriesAfter li cnt) m = case Map.lookup (GetEntriesAfter li cnt) m of
    Just (QrEntriesAfter v) -> v
    _ -> error "Invariant Error: hasQueryResult EntriesAfter failed to find EntriesAfter"
  {-# INLINE hasQueryResult #-}

instance HasQueryResult InfoAndEntriesAfter (LogIndex, Term, Seq LogEntry) where
  hasQueryResult (InfoAndEntriesAfter mli cnt) m = case Map.lookup (GetInfoAndEntriesAfter mli cnt) m of
    Just (QrInfoAndEntriesAfter v) -> v
    _ -> error "Invariant Error: hasQueryResult InfoAndEntriesAfter failed to find InfoAndEntriesAfter"
  {-# INLINE hasQueryResult #-}

data QueryApi =
  Query (Set AtomicQuery) (MVar (Map AtomicQuery QueryResult)) |
  Update UpdateLogs |
  Tick Tock
  deriving (Eq)

newtype LogServiceChannel =
  LogServiceChannel (Unagi.InChan QueryApi, MVar (Maybe (Unagi.Element QueryApi, IO QueryApi), Unagi.OutChan QueryApi))

instance Comms QueryApi LogServiceChannel where
  initComms = LogServiceChannel <$> initCommsUnagi
  readComm (LogServiceChannel (_,o)) = readCommUnagi o
  readComms (LogServiceChannel (_,o)) = readCommsUnagi o
  writeComm (LogServiceChannel (i,_)) = writeCommUnagi i

data LogEnv = LogEnv
  { _logQueryChannel :: LogServiceChannel
  , _debugPrint :: (String -> IO ())
  , _dbConn :: Maybe Connection }
makeLenses ''LogEnv

type LogThread = RWST LogEnv () (LogState LogEntry) IO
