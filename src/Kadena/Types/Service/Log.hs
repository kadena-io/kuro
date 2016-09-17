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

module Kadena.Types.Service.Log
  ( LogState(..)
  , lsVolatileLogEntries, lsPersistedLogEntries, lsLastApplied, lsLastLogIndex, lsNextLogIndex, lsCommitIndex
  , lsLastPersisted, lsLastLogTerm, lsLastLogHash, lsLastCryptoVerified
  , LogApi(..)
  , initLogState
  , UpdateLogs(..)
  , AtomicQuery(..)
  , QueryResult(..)
  , QueryApi(..)
  , evalQuery
  , CryptoWorkerStatus(..)
  , LogEnv(..)
  , logQueryChannel, commitChannel, internalEvent, debugPrint
  , dbConn, evidence, keySet, publishMetric, cryptoWorkerTVar
  , HasQueryResult(..)
  , LogThread
  , LogServiceChannel(..)
  , FirstEntry(..), LastEntry(..), MaxIndex(..), EntryCount(..), SomeEntry(..)
  , LogInfoForNextIndex(..) , LastLogHash(..), LastLogTerm(..)
  , EntriesAfter(..), InfoAndEntriesAfter(..)
  , LastApplied(..), LastLogIndex(..), NextLogIndex(..), CommitIndex(..)
  , UnappliedEntries(..)
  -- ReExports
  , module X
  , LogIndex(..)
  , KeySet(..)
  -- for tesing
  , newEntriesToLog
  , hashNewEntry
  , updateLogEntriesHashes
  ) where


import Control.Lens hiding (Index, (|>))

import Control.Concurrent (MVar)
import Control.Concurrent.STM.TVar (TVar)
import qualified Control.Concurrent.Chan.Unagi as Unagi
import Control.Monad.Trans.RWS.Strict

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Serialize hiding (get)

import Database.SQLite.Simple (Connection(..))

import GHC.Generics

import Kadena.Types.Base
import Kadena.Types.Metric
import Kadena.Types.Config (KeySet(..))
import Kadena.Types.Log
import qualified Kadena.Types.Log as X
import Kadena.Types.Comms
import Kadena.Types.Message.Signed
import Kadena.Types.Message.CMD

import Kadena.Types.Evidence (EvidenceChannel)
import Kadena.Types.Service.Commit (CommitChannel)

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
  -- | called by leaders sending appendEntries.
  -- given a replica's nextIndex, get the index and term to send as
  -- prevLog(Index/Term)
  -- | get every entry that hasn't been applied yet (betweek LastApplied and CommitIndex)
  getUnappliedEntries :: a -> Maybe LogEntries
  getUncommitedHashes :: a -> Map LogIndex ByteString
  getUnpersisted      :: a -> Maybe LogEntries
  getUnverifiedEntries :: a -> Maybe LogEntries
  logInfoForNextIndex :: Maybe LogIndex -> a -> (LogIndex,Term)
  -- | Latest hash or empty
  lastLogHash :: a -> ByteString
  -- | Latest term on log or 'startTerm'
  lastLogTerm :: a -> Term
  -- | get entries after index to beginning, with limit, for AppendEntries message.
  -- TODO make monadic to get 8000 limit from config.
  getEntriesAfter :: LogIndex -> Int -> a -> LogEntries
  updateLogs :: UpdateLogs -> a -> a

data LogState = LogState
  { _lsVolatileLogEntries  :: !LogEntries
  , _lsPersistedLogEntries :: !PersistedLogEntries
  , _lsLastApplied      :: !LogIndex
  , _lsLastLogIndex     :: !LogIndex
  , _lsLastLogHash      :: !ByteString
  , _lsNextLogIndex     :: !LogIndex
  , _lsCommitIndex      :: !LogIndex
  , _lsLastPersisted    :: !LogIndex
  , _lsLastCryptoVerified :: !LogIndex
  , _lsLastLogTerm      :: !Term
  } deriving (Show, Eq, Generic)
makeLenses ''LogState

initLogState :: LogState
initLogState = LogState
  { _lsVolatileLogEntries = lesEmpty
  , _lsPersistedLogEntries = plesEmpty
  , _lsLastApplied = startIndex
  , _lsLastLogIndex = startIndex
  , _lsLastLogHash = mempty
  , _lsNextLogIndex = startIndex + 1
  , _lsCommitIndex = startIndex
  , _lsLastPersisted = startIndex
  , _lsLastCryptoVerified = startIndex
  , _lsLastLogTerm = startTerm
  }

instance LogApi (LogState) where
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

  firstEntry ls =
    let ples = ls ^. lsPersistedLogEntries
        vles = ls ^. lsVolatileLogEntries
    in if not $ plesNull ples
       then plesMinEntry ples
       else lesMinEntry vles
  {-# INLINE firstEntry #-}

  lastEntry ls =
    let ples = ls ^. lsPersistedLogEntries
        vles = ls ^. lsVolatileLogEntries
    in if not $ lesNull vles
       then lesMaxEntry $ vles
       else if not $ plesNull ples
            then plesMaxEntry ples
            else Nothing
  {-# INLINE lastEntry #-}

  maxIndex ls = maybe startIndex _leLogIndex (lastEntry ls)
  {-# INLINE maxIndex #-}

  entryCount ls =
    let ples = ls ^. lsPersistedLogEntries
        vles = ls ^. lsVolatileLogEntries
    in (plesCnt ples) + (lesCnt vles)
  {-# INLINE entryCount #-}

  lookupEntry i ls =
    let ples = ls ^. (lsPersistedLogEntries.pLogEntries)
        vles = ls ^. lsVolatileLogEntries
        lookup' i' (LogEntries les) = Map.lookup i' les
    in case lookup' i vles of
      Nothing -> case Map.lookupLE i ples of
        Nothing -> Nothing
        Just (_, ples') -> case lookup' i ples' of
          Nothing -> Nothing
          v -> v
      v -> v
  {-# INLINE lookupEntry #-}

  getUncommitedHashes ls =
    let ci  = commitIndex ls
        vles = ls ^. lsVolatileLogEntries
    in _leHash <$> (_logEntries $ lesGetSection (Just $ ci + 1) Nothing vles)
  {-# INLINE getUncommitedHashes #-}

  getUnappliedEntries ls =
    let lv = ls ^. lsLastCryptoVerified
        vles = ls ^. lsVolatileLogEntries
        ci = commitIndex ls
        finalIdx = if lv > ci then ci else lv
        la = lastApplied ls
        les = if la < finalIdx
              then Just $ lesGetSection (Just $ la + 1) (Just finalIdx) vles
              else Nothing
    in case les of
         Just (LogEntries v) | Map.null v -> Nothing
                | otherwise  -> Just $ LogEntries v
         Nothing -> Nothing
  {-# INLINE getUnappliedEntries #-}

  getUnpersisted ls =
    let la = lastApplied ls
        lp = lastPersisted ls
        vles = ls ^. lsVolatileLogEntries
        uples = lesGetSection (Just $ lp + 1) (Just $ la) vles
    in if lp < la
       then if Map.null $ _logEntries uples
            then Nothing
            else Just uples
       else Nothing
  {-# INLINE getUnpersisted #-}

  getUnverifiedEntries ls =
    let lstIndex = maxIndex ls
        fstIndex = ls ^. lsLastCryptoVerified
        vles = ls ^. lsVolatileLogEntries
        les = if fstIndex < lstIndex
              then Just $! lesGetSection (Just $ fstIndex + 1) Nothing vles
              else Nothing
    in case les of
      Nothing -> Nothing
      Just les' -> Just les'
  {-# INLINE getUnverifiedEntries #-}

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

  getEntriesAfter pli cnt ls = -- Seq.take cnt . Seq.drop (fromIntegral $ pli + 1) . viewLogSeq
    let lp = lastPersisted ls
        vles = ls ^. lsVolatileLogEntries
    in if pli >= lp
       then lesGetSection (Just $ pli + 1) (Just $ pli + fromIntegral cnt) vles
       else let ples = ls ^. lsPersistedLogEntries
                firstPart = plesGetSection (Just $ pli + 1) (Just $ pli + fromIntegral cnt) ples
            in --if lesCnt firstPart == cnt
               --then firstPart
               --else lesUnion firstPart (lesGetSection (Just $ pli + 1) (Just $ pli + fromIntegral cnt) vles)
               lesUnion firstPart (lesGetSection (Just $ pli + 1) (Just $ pli + fromIntegral cnt) vles)
  {-# INLINE getEntriesAfter #-}

  updateLogs (ULNew nle) ls = appendLogEntry nle ls
  updateLogs (ULReplicate ReplicateLogEntries{..}) ls = addLogEntriesAt _rlePrvLogIdx _rleEntries ls
  updateLogs (ULCommitIdx UpdateCommitIndex{..}) ls = ls {_lsCommitIndex = _uci}
  updateLogs (UpdateLastApplied li) ls = ls {_lsLastApplied = li}
  updateLogs (UpdateVerified (VerifiedLogEntries res)) ls = ls
    { _lsVolatileLogEntries = applyCryptoVerify' res (ls ^. (lsVolatileLogEntries))
    , _lsLastCryptoVerified = LogIndex $ fst $ IntMap.findMax res }
  {-# INLINE updateLogs  #-}

applyCryptoVerify' :: IntMap CryptoVerified -> LogEntries -> LogEntries
applyCryptoVerify' m (LogEntries les) = LogEntries $! fmap (\le@LogEntry{..} -> case IntMap.lookup (fromIntegral $ _leLogIndex) m of
      Nothing -> le
      Just c -> le { _leCommand = _leCommand { _cmdCryptoVerified = c }}
      ) les
{-# INLINE applyCryptoVerify' #-}

addLogEntriesAt :: LogIndex -> LogEntries -> LogState -> LogState
addLogEntriesAt pli newLEs ls =
  let preceedingEntry = lookupEntry pli ls
      existingEntries = lesGetSection Nothing (Just pli) (ls ^. lsVolatileLogEntries)
      prepedLES = updateLogEntriesHashes preceedingEntry newLEs
      alreadyStored = case lesMaxEntry prepedLES of
        -- because incremental hashes, if our "new" ones have the same lastHash as whatever we have saved already, we've already stored the lot of them
        Nothing -> error "Invariant Error: addLogEntriesAt called with an empty replicateLogEntries chunk"
        Just lastLe -> case lesLookupEntry (_leLogIndex lastLe) (ls ^. lsVolatileLogEntries) of
          Nothing -> False
          Just ourLastLe -> _leHash ourLastLe == _leHash lastLe
      ls' = lesUnion prepedLES existingEntries
      (lastIdx',lastTerm',lastHash') =
        if Map.null $ _logEntries ls'
        then error "Invariant Error: addLogEntries attempted called on an null map!"
        else let e = snd $ Map.findMax (ls' ^. logEntries) in (_leLogIndex e, _leTerm e, _leHash e)
  in if alreadyStored
     then ls -- because messages can come out of order/redundant it's possible that we've already replicated this chunk.
     else ls { _lsVolatileLogEntries = ls'
             , _lsLastLogIndex = lastIdx'
             , _lsLastLogHash = lastHash'
             , _lsNextLogIndex = lastIdx' + 1
             , _lsLastLogTerm = lastTerm'
             }
{-# INLINE addLogEntriesAt #-}

-- Since the only node to ever append a log entry is the Leader we can start keeping the logs in sync here
-- TODO: this needs to handle picking the right LogIndex
appendLogEntry :: NewLogEntries -> LogState -> LogState
appendLogEntry NewLogEntries{..} ls = case lastEntry ls of
    Just ple -> let
        nle = newEntriesToLog (_nleTerm) (_leHash ple) (ls ^. lsNextLogIndex) _nleEntries
        ls' = ls { _lsVolatileLogEntries = LogEntries $ Map.union (_logEntries nle) (ls ^. (lsVolatileLogEntries.logEntries)) }
        lastLog' = lastEntry ls'
        lastIdx' = maybe (ls ^. lsLastLogIndex) _leLogIndex lastLog'
        lastTerm' = maybe (ls ^. lsLastLogTerm) _leTerm lastLog'
        lastHash' = maybe (ls ^. lsLastLogHash) _leHash lastLog'
      in ls' { _lsLastLogIndex = lastIdx'
             , _lsLastLogHash = lastHash'
             , _lsNextLogIndex = lastIdx' + 1
             , _lsLastLogTerm  = lastTerm' }
    Nothing -> let
        nle = newEntriesToLog (_nleTerm) (B.empty) (ls ^. lsNextLogIndex) _nleEntries
        ls' = ls { _lsVolatileLogEntries = nle }
        lastLog' = case lesMaxEntry nle of
                     Nothing -> plesMaxEntry (ls ^. lsPersistedLogEntries)
                     v -> v
        lastIdx' = maybe (ls ^. lsLastLogIndex) _leLogIndex lastLog'
        lastTerm' = maybe (ls ^. lsLastLogTerm) _leTerm lastLog'
        lastHash' = maybe (ls ^. lsLastLogHash) _leHash lastLog'
      in ls' { _lsLastLogIndex = lastIdx'
             , _lsLastLogHash = lastHash'
             , _lsNextLogIndex = lastIdx' + 1
             , _lsLastLogTerm  = lastTerm' }
{-# INLINE appendLogEntry #-}

newEntriesToLog :: Term -> ByteString -> LogIndex -> [Command] -> LogEntries
newEntriesToLog ct prevHash idx cmds = res `seq` LogEntries res
  where
    res = Map.fromList $! go prevHash idx cmds
    go _ _ [] = []
    go prevHash' i [c] = [(i,LogEntry ct i c (hashNewEntry prevHash' ct i c))]
    go prevHash' i (c:cs) = let
        newHash = hashNewEntry prevHash' ct i c
      in (:) (i, LogEntry ct i c newHash) $! go newHash (i + 1) cs
{-# INLINE newEntriesToLog #-}

updateLogEntriesHashes :: Maybe LogEntry -> LogEntries -> LogEntries
updateLogEntriesHashes preceedingEntry (LogEntries les) = LogEntries $! Map.fromAscList $! go (Map.toAscList les) preceedingEntry
  where
    go [] _ = []
    go ((k,le):rest) pEntry =
      let hashedEntry = hashLogEntry pEntry le
      in (hashedEntry `seq` (k,hashedEntry)) : go rest (Just hashedEntry)
--  case firstOf (ix i) ls of
--    Just _ -> updateLogHashesFromIndex (succ i) $
--              over (logEntries) (Seq.adjust (hashLogEntry (firstOf (ix (i - 1)) ls)) (fromIntegral i)) ls
--    Nothing -> ls
{-# INLINE updateLogEntriesHashes #-}

hashNewEntry :: ByteString -> Term -> LogIndex -> Command -> ByteString
hashNewEntry prevHash leTerm' leLogIndex' cmd = hash $! (encode $! LEWire (leTerm', leLogIndex', sigCmd cmd, prevHash))
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
  QrLastLogHash ByteString |
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

data QueryApi =
  Query (Set AtomicQuery) (MVar (Map AtomicQuery QueryResult)) |
  Update UpdateLogs |
  NeedCacheEvidence (Set LogIndex) (MVar (Map LogIndex ByteString)) |
  Tick Tock
  deriving (Eq)

newtype LogServiceChannel =
  LogServiceChannel (Unagi.InChan QueryApi, MVar (Maybe (Unagi.Element QueryApi, IO QueryApi), Unagi.OutChan QueryApi))

instance Comms QueryApi LogServiceChannel where
  initComms = LogServiceChannel <$> initCommsUnagi
  readComm (LogServiceChannel (_,o)) = readCommUnagi o
  readComms (LogServiceChannel (_,o)) = readCommsUnagi o
  writeComm (LogServiceChannel (i,_)) = writeCommUnagi i

data CryptoWorkerStatus =
  Unprocessed LogEntries |
  Processing |
  Idle
  deriving (Show, Eq)

data LogEnv = LogEnv
  { _logQueryChannel :: !LogServiceChannel
  , _internalEvent :: !InternalEventChannel
  , _commitChannel :: !CommitChannel
  , _evidence :: !EvidenceChannel
  , _keySet :: !KeySet
  , _cryptoWorkerTVar :: !(TVar CryptoWorkerStatus)
  , _debugPrint :: !(String -> IO ())
  , _dbConn :: !(Maybe Connection)
  , _publishMetric :: !(Metric -> IO ())}
makeLenses ''LogEnv

type LogThread = RWST LogEnv () LogState IO
