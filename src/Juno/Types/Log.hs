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

module Juno.Types.Log
  ( LogEntry(..), leTerm, leLogIndex, leCommand, leHash
  , Log(..), lEntries
  , LEWire(..), encodeLEWire, decodeLEWire, decodeLEWire', toSeqLogEntry
  , LogState(..), logEntries, lastApplied, lastLogIndex, nextLogIndex, commitIndex
  , LogApi(..)
  , initLogState
  , ReplicateLogEntries(..), rleMinLogIdx, rleMaxLogIdx, rlePrvLogIdx, rleEntries
  , toReplicateLogEntries
  , NewLogEntries(..), nleTerm, nleEntries
  , UpdateCommitIndex(..), uci
  , UpdateLogs(..)
  , AtomicQuery(..)
  , QueryResult(..)
  -- used for testing
  , hashLogEntry
  ) where

import Control.Parallel.Strategies
import Control.Concurrent (MVar, putMVar)
import Control.Lens hiding (Index, (|>))
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict
import Codec.Digest.SHA
import qualified Control.Lens as Lens
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Serialize hiding (get)
import Data.Maybe (fromJust)
import Data.Foldable
import Data.Thyme.Time.Core ()
import GHC.Generics

import Juno.Types.Base
import Juno.Types.Config
import Juno.Types.Message.Signed
import Juno.Types.Message.CMD
import Juno.Types.Comms

data LogEntry = LogEntry
  { _leTerm    :: !Term
  , _leLogIndex :: !LogIndex
  , _leCommand :: !Command
  , _leHash    :: !ByteString
  }
  deriving (Show, Eq, Generic)
makeLenses ''LogEntry

newtype Log a = Log { _lEntries :: Seq a }
    deriving (Eq,Show,Ord,Generic,Monoid,Functor,Foldable,Traversable,Applicative,Monad,NFData)
makeLenses ''Log
instance (t ~ Log a) => Rewrapped (Log a) t
instance Wrapped (Log a) where
    type Unwrapped (Log a) = Seq a
    _Wrapped' = iso _lEntries Log
instance Cons (Log a) (Log a) a a where
    _Cons = _Wrapped . _Cons . mapping _Unwrapped
instance Snoc (Log a) (Log a) a a where
    _Snoc = _Wrapped . _Snoc . firsting _Unwrapped
type instance IxValue (Log a) = a
type instance Lens.Index (Log a) = LogIndex
instance Ixed (Log a) where ix i = lEntries.ix (fromIntegral i)

data LEWire = LEWire (Term, LogIndex, SignedRPC, ByteString)
  deriving (Show, Generic)
instance Serialize LEWire

decodeLEWire' :: Maybe ReceivedAt -> KeySet -> LEWire -> Either String LogEntry
decodeLEWire' !ts !ks (LEWire !(t,i,cmd,hsh)) = case fromWire ts ks cmd of
      Left !err -> Left $!err
      Right !cmd' -> Right $! LogEntry t i cmd' hsh
{-# INLINE decodeLEWire' #-}

-- TODO: check if `toSeqLogEntry ele = Seq.fromList <$> sequence ele` is fusable?
toSeqLogEntry :: [Either String LogEntry] -> Either String (Seq LogEntry)
toSeqLogEntry !ele = go ele mempty
  where
    go [] s = Right $! s
    go (Right le:les) s = go les (s |> le)
    go (Left err:_) _ = Left $! err
{-# INLINE toSeqLogEntry #-}

decodeLEWire :: Maybe ReceivedAt -> KeySet -> [LEWire] -> Either String (Seq LogEntry)
decodeLEWire !ts !ks !les = go les Seq.empty
  where
    go [] s = Right $! s
    go (LEWire !(t,i,cmd,hsh):ls) v = case fromWire ts ks cmd of
      Left err -> Left $! err
      Right cmd' -> go ls (v |> LogEntry t i cmd' hsh)
{-# INLINE decodeLEWire #-}

encodeLEWire :: NodeId -> PublicKey -> PrivateKey -> Seq LogEntry -> [LEWire]
encodeLEWire nid pubKey privKey les =
  (\LogEntry{..} -> LEWire (_leTerm, _leLogIndex, toWire nid pubKey privKey _leCommand, _leHash)) <$> toList les
{-# INLINE encodeLEWire #-}

data ReplicateLogEntries = ReplicateLogEntries
  { _rleMinLogIdx :: LogIndex
  , _rleMaxLogIdx :: LogIndex
  , _rlePrvLogIdx :: LogIndex
  , _rleEntries :: Seq LogEntry
  } deriving (Show, Eq, Generic)
makeLenses ''ReplicateLogEntries

data NewLogEntries = NewLogEntries
  { _nleTerm :: Term
  , _nleEntries :: [Command]
  } deriving (Show, Eq, Generic)
makeLenses ''NewLogEntries

newtype UpdateCommitIndex = UpdateCommitIndex {_uci :: LogIndex}
  deriving (Show, Eq, Generic)
makeLenses ''UpdateCommitIndex

data UpdateLogs =
  ULReplicate ReplicateLogEntries |
  ULNew NewLogEntries |
  ULCommitIdx UpdateCommitIndex
  deriving (Show, Eq, Generic)

class LogApi a where
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
  logInfoForNextIndex :: Maybe LogIndex -> a -> (LogIndex,Term)
  -- | Latest hash or empty
  lastLogHash :: a -> ByteString
  -- | Latest term on log or 'startTerm'
  lastLogTerm :: a -> Term
  -- | get entries after index to beginning, with limit, for AppendEntries message.
  -- TODO make monadic to get 8000 limit from config.
  getEntriesAfter :: LogIndex -> Int -> a -> Seq LogEntry
  updateLogs :: UpdateLogs -> a -> a

seqHead :: Seq a -> Maybe a
seqHead s = case Seq.viewl s of
  (e Seq.:< _) -> Just e
  _            -> Nothing

seqTail :: Seq a -> Maybe a
seqTail s = case Seq.viewr s of
  (_ Seq.:> e) -> Just e
  _        -> Nothing

toReplicateLogEntries :: LogIndex -> Seq LogEntry -> Either String ReplicateLogEntries
toReplicateLogEntries prevLogIndex les = do
  let minLogIdx = _leLogIndex $ fromJust $ seqHead les
      maxLogIdx = _leLogIndex $ fromJust $ seqTail les
  if prevLogIndex /= minLogIdx - 1
  then Left $ "PrevLogIndex ("
            ++ show prevLogIndex
            ++ ") should be -1 the head entry's ("
            ++ show minLogIdx
            ++ ")"
  else if minLogIdx > maxLogIdx
  then Left $ "Min"
            ++ show prevLogIndex
            ++ "> Max"
            ++ show minLogIdx
            ++ " where Length was "
            ++ show (Seq.length les)
  else if fromIntegral (maxLogIdx - minLogIdx + 1) /= Seq.length les && maxLogIdx /= startIndex && minLogIdx /= startIndex
  then Left $ "HeadLogIdx - TailLogIdx + 1 != length les: "
            ++ show maxLogIdx
            ++ " - "
            ++ show minLogIdx
            ++ " + 1 != "
            ++ show (Seq.length les)
  else -- TODO: add a protection in here to check that Seq's LogIndexs are
    -- strictly increasing by 1 from right to left
    return $ ReplicateLogEntries { _rleMinLogIdx = minLogIdx
                                 , _rleMaxLogIdx = maxLogIdx
                                 , _rlePrvLogIdx = prevLogIndex
                                 , _rleEntries   = les }

data LogState a = LogState
  { _logEntries       :: !(Log a)
  , _lastApplied      :: !LogIndex
  , _lastLogIndex     :: !LogIndex
  , _nextLogIndex     :: !LogIndex
  , _commitIndex      :: !LogIndex
  } deriving (Show, Eq, Generic)
makeLenses ''LogState

viewLogSeq :: LogState LogEntry -> Seq LogEntry
viewLogSeq = view (logEntries.lEntries)

viewLogs :: LogState LogEntry -> Log LogEntry
viewLogs = view logEntries

initLogState :: LogState LogEntry
initLogState = LogState
  { _logEntries = mempty
  , _lastApplied = startIndex
  , _lastLogIndex = startIndex
  , _nextLogIndex = startIndex + 1
  , _commitIndex = startIndex
  }

instance LogApi (LogState LogEntry) where
  firstEntry ls = case viewLogs ls of
    (e :< _) -> Just e
    _        -> Nothing

  lastEntry ls = case viewLogs ls of
    (_ :> e) -> Just e
    _        -> Nothing

  maxIndex ls = maybe startIndex _leLogIndex (lastEntry ls)

  entryCount ls = fromIntegral . Seq.length . viewLogSeq $ ls

  lookupEntry i = firstOf (ix i) . viewLogs

  takeEntries t ls = case Seq.take (fromIntegral t) $ viewLogSeq ls of
    v | Seq.null v -> Nothing
      | otherwise  -> Just v

  logInfoForNextIndex Nothing          _  = (startIndex, startTerm)
  logInfoForNextIndex (Just myNextIdx) ls = let pli = myNextIdx - 1 in
    case lookupEntry pli ls of
          Just LogEntry{..} -> (pli, _leTerm)
          -- this shouldn't happen, because nextIndex - 1 should always be at
          -- most our last entry
          Nothing -> (startIndex, startTerm)

  lastLogHash = maybe mempty _leHash . lastEntry

  lastLogTerm ls = maybe startTerm _leTerm $ lastEntry ls

  getEntriesAfter pli cnt = Seq.take cnt . Seq.drop (fromIntegral $ pli + 1) . viewLogSeq

  updateLogs (ULNew nle) ls = appendLogEntry nle ls
  updateLogs (ULReplicate ReplicateLogEntries{..}) ls = addLogEntriesAt _rlePrvLogIdx _rleEntries ls
  updateLogs (ULCommitIdx UpdateCommitIndex{..}) ls = ls {_commitIndex = _uci}


addLogEntriesAt :: LogIndex -> Seq LogEntry -> LogState LogEntry -> LogState LogEntry
addLogEntriesAt pli newLEs ls =
  let ls' = updateLogHashesFromIndex (pli + 1)
                . over (lEntries) ((Seq.>< newLEs)
                . Seq.take (fromIntegral pli + 1))
                $ _logEntries ls
      lastIdx = case ls' ^. lEntries of
        (_ :> e) -> _leLogIndex e
        _        -> startIndex
  in ls { _logEntries = ls'
        , _lastLogIndex = lastIdx
        , _nextLogIndex = lastIdx + 1
        }

-- Since the only node to ever append a log entry is the Leader we can start keeping the logs in sync here
-- TODO: this needs to handle picking the right LogIndex
appendLogEntry :: NewLogEntries -> LogState LogEntry -> LogState LogEntry
appendLogEntry NewLogEntries{..} ls = case lastEntry ls of
    Just ple -> let
        nle = newEntriesToLog (_nleTerm) (_leHash ple) (ls ^. nextLogIndex) _nleEntries
        ls' = ls { _logEntries = Log $ (Seq.><) (viewLogSeq ls) nle }
        lastIdx' = maybe (ls ^. lastLogIndex) _leLogIndex $ seqTail nle
      in ls' { _lastLogIndex = lastIdx'
             , _nextLogIndex = lastIdx' + 1 }
    Nothing -> let
        nle = newEntriesToLog (_nleTerm) (B.empty) (ls ^. nextLogIndex) _nleEntries
        ls' = ls { _logEntries = Log nle }
        lastIdx' = maybe (ls ^. lastLogIndex) _leLogIndex $ seqTail nle
      in ls' { _lastLogIndex = lastIdx'
             , _nextLogIndex = lastIdx' + 1 }

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

hashNewEntry :: ByteString -> Term -> LogIndex -> Command -> ByteString
hashNewEntry prevHash leTerm' leLogIndex' cmd = hash SHA256 (encode $ LEWire (leTerm', leLogIndex', sigCmd cmd, prevHash))
  where
    sigCmd Command{ _cmdProvenance = ReceivedMsg{ _pDig = dig, _pOrig = bdy }} =
      SignedRPC dig bdy
    sigCmd Command{ _cmdProvenance = NewMsg } =
      error "Invariant Failure: for a command to be in a log entry, it needs to have been received!"

-- TODO: This uses the old decode encode trick and should be changed...
hashLogEntry :: Maybe LogEntry -> LogEntry -> LogEntry
hashLogEntry (Just LogEntry{ _leHash = prevHash }) le@LogEntry{..} =
  le { _leHash = hash SHA256 (encode $ LEWire (_leTerm, _leLogIndex, getCmdSignedRPC le, prevHash))}
hashLogEntry Nothing le@LogEntry{..} =
  le { _leHash = hash SHA256 (encode $ LEWire (_leTerm, _leLogIndex, getCmdSignedRPC le, mempty))}

getCmdSignedRPC :: LogEntry -> SignedRPC
getCmdSignedRPC LogEntry{ _leCommand = Command{ _cmdProvenance = ReceivedMsg{ _pDig = dig, _pOrig = bdy }}} =
  SignedRPC dig bdy
getCmdSignedRPC LogEntry{ _leCommand = Command{ _cmdProvenance = NewMsg }} =
  error "Invariant Failure: for a command to be in a log entry, it needs to have been received!"

data AtomicQuery =
  GetFirstEntry |
  GetLastEntry |
  GetMaxIndex |
  GetEntryCount |
  GetEntry LogIndex |
  TakeEntries LogIndex |
  GetLogInfoForNextIndex (Maybe LogIndex) |
  GetLastLogHash |
  GetLastLogTerm |
  GetEntriesAfter LogIndex Int
  deriving (Eq, Show)

data QueryResult =
  QrFirstEntry (Maybe LogEntry) |
  QrLastEntry (Maybe LogEntry) |
  QrMaxIndex LogIndex |
  QrEntryCount Int |
  QrSomeEntry (Maybe LogEntry) |
  QrTakenEntries (Maybe (Seq LogEntry)) |
  QrLogInfoForNextIndex (LogIndex,Term) |
  QrLastLogHash ByteString |
  QrLastLogTerm Term |
  QrEntriesAfter (Seq LogEntry)
  deriving (Eq, Show)

data FirstEntry = FirstEntry deriving (Eq,Show)
data LastEntry = LastEntry deriving (Eq,Show)
data MaxIndex = MaxIndex deriving (Eq,Show)
data EntryCount = EntryCount deriving (Eq,Show)
data SomeEntry = SomeEntry deriving (Eq,Show)
data TakenEntries = TakenEntries deriving (Eq,Show)
data LogInfoForNextIndex = LogInfoForNextIndex deriving (Eq,Show)
data LastLogHash = LastLogHash deriving (Eq,Show)
data LastLogTerm = LastLogTerm deriving (Eq,Show)
data EntriesAfter = EntriesAfter deriving (Eq,Show)

evalQuery :: LogApi a => AtomicQuery -> a -> QueryResult
evalQuery GetFirstEntry a = QrFirstEntry $ firstEntry a
evalQuery GetLastEntry a = QrLastEntry $ lastEntry a
evalQuery GetMaxIndex a = QrMaxIndex $ maxIndex a
evalQuery GetEntryCount a = QrEntryCount $ entryCount a
evalQuery (GetEntry li) a = QrSomeEntry $ lookupEntry li a
evalQuery (TakeEntries li) a = QrTakenEntries $ takeEntries li a
evalQuery (GetLogInfoForNextIndex mli) a = QrLogInfoForNextIndex $ logInfoForNextIndex mli a
evalQuery GetLastLogHash a = QrLastLogHash $ lastLogHash a
evalQuery GetLastLogTerm a = QrLastLogTerm $ lastLogTerm a
evalQuery (GetEntriesAfter li cnt) a = QrEntriesAfter $ getEntriesAfter li cnt a
{-# INLINE evalQuery #-}

class HasQueryResult a b | a -> b where
  hasQueryResult :: a -> [QueryResult] -> b

instance HasQueryResult FirstEntry (Maybe LogEntry) where
  hasQueryResult FirstEntry [] = error "Invariant Error: hasQueryResult FirstEntry failed to find FirstEntry"
  hasQueryResult FirstEntry (QrFirstEntry v:_) = v
  hasQueryResult FirstEntry (_:qrs) = hasQueryResult FirstEntry qrs

instance HasQueryResult LastEntry (Maybe LogEntry) where
  hasQueryResult LastEntry [] = error "Invariant Error: hasQueryResult LastEntry failed to find LastEntry"
  hasQueryResult LastEntry (QrLastEntry v:_) = v
  hasQueryResult LastEntry (_:qrs) = hasQueryResult LastEntry qrs

instance HasQueryResult MaxIndex LogIndex where
  hasQueryResult MaxIndex [] = error "Invariant Error: hasQueryResult MaxIndex failed to find MaxIndex"
  hasQueryResult MaxIndex (QrMaxIndex v:_) = v
  hasQueryResult MaxIndex (_:qrs) = hasQueryResult MaxIndex qrs

instance HasQueryResult EntryCount Int where
  hasQueryResult EntryCount [] = error "Invariant Error: hasQueryResult EntryCount failed to find EntryCount"
  hasQueryResult EntryCount (QrEntryCount v:_) = v
  hasQueryResult EntryCount (_:qrs) = hasQueryResult EntryCount qrs

instance HasQueryResult SomeEntry (Maybe LogEntry) where
  hasQueryResult SomeEntry [] = error "Invariant Error: hasQueryResult SomeEntry failed to find SomeEntry"
  hasQueryResult SomeEntry (QrSomeEntry v:_) = v
  hasQueryResult SomeEntry (_:qrs) = hasQueryResult SomeEntry qrs

instance HasQueryResult TakenEntries (Maybe (Seq LogEntry)) where
  hasQueryResult TakenEntries [] = error "Invariant Error: hasQueryResult TakenEntries failed to find TakenEntries"
  hasQueryResult TakenEntries (QrTakenEntries v:_) = v
  hasQueryResult TakenEntries (_:qrs) = hasQueryResult TakenEntries qrs

instance HasQueryResult LogInfoForNextIndex (LogIndex,Term) where
  hasQueryResult LogInfoForNextIndex [] = error "Invariant Error: hasQueryResult LogInfoForNextIndex failed to find LogInfoForNextIndex"
  hasQueryResult LogInfoForNextIndex (QrLogInfoForNextIndex v:_) = v
  hasQueryResult LogInfoForNextIndex (_:qrs) = hasQueryResult LogInfoForNextIndex qrs

instance HasQueryResult LastLogHash ByteString where
  hasQueryResult LastLogHash [] = error "Invariant Error: hasQueryResult LastLogHash failed to find LastLogHash"
  hasQueryResult LastLogHash (QrLastLogHash v:_) = v
  hasQueryResult LastLogHash (_:qrs) = hasQueryResult LastLogHash qrs

instance HasQueryResult LastLogTerm Term where
  hasQueryResult LastLogTerm [] = error "Invariant Error: hasQueryResult LastLogTerm failed to find LastLogTerm"
  hasQueryResult LastLogTerm (QrLastLogTerm v:_) = v
  hasQueryResult LastLogTerm (_:qrs) = hasQueryResult LastLogTerm qrs

instance HasQueryResult EntriesAfter (Seq LogEntry) where
  hasQueryResult EntriesAfter [] = error "Invariant Error: hasQueryResult EntriesAfter failed to find EntriesAfter"
  hasQueryResult EntriesAfter (QrEntriesAfter v:_) = v
  hasQueryResult EntriesAfter (_:qrs) = hasQueryResult EntriesAfter qrs

data QueryApi =
  Query [AtomicQuery] (MVar [QueryResult]) |
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
  { _updateChannel :: LogServiceChannel}


type LogThread = RWST LogEnv () (LogState LogEntry) IO

runQuery :: QueryApi -> LogThread ()
runQuery (Query aq mv) = do
  a' <- get
  qr <- return ((`evalQuery` a') <$> aq)
  liftIO $ putMVar mv qr
runQuery (Update ul) = modify (\a' -> updateLogs ul a')
