{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
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
  ) where

import Control.Parallel.Strategies
import Control.Lens hiding (Index, (|>))
import Codec.Digest.SHA
import qualified Control.Lens as Lens
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Serialize
import Data.Maybe (fromJust)
import Data.Foldable
import Data.IORef
import Data.Thyme.Time.Core ()
import GHC.Generics

import Juno.Types.Base
import Juno.Types.Config
import Juno.Types.Message.Signed
import Juno.Types.Message.CMD

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
  -- | Query current state
  viewLogState :: Getting t (a) t -> IORef a -> IO t
  updateLogState :: (a -> a) -> IORef a -> IO ()
  -- | Get the first entry
  firstEntry :: IORef a -> IO (Maybe LogEntry)
  firstEntry' :: a -> Maybe LogEntry
  -- | Get last entry.
  lastEntry :: IORef a -> IO (Maybe LogEntry)
  lastEntry' :: a -> Maybe LogEntry
  -- | Get largest index in ledger.
  maxIndex :: IORef a -> IO LogIndex
  maxIndex' :: a -> LogIndex
  -- | Get count of entries in ledger.
  entryCount :: IORef a -> IO Int
  entryCount' :: a -> Int
  -- | Safe index
  lookupEntry :: LogIndex -> IORef a -> IO (Maybe LogEntry)
  lookupEntry' :: LogIndex -> a -> Maybe LogEntry
  -- | Take operation: `takeEntries 3 $ Log $ Seq.fromList [0,1,2,3,4] == fromList [0,1,2]`
  takeEntries :: LogIndex -> IORef a -> IO (Maybe (Seq LogEntry))
  takeEntries' :: LogIndex -> a -> (Maybe (Seq LogEntry))
  -- | called by leaders sending appendEntries.
  -- given a replica's nextIndex, get the index and term to send as
  -- prevLog(Index/Term)
  logInfoForNextIndex :: Maybe LogIndex -> IORef a -> IO (LogIndex,Term)
  logInfoForNextIndex' :: Maybe LogIndex -> a -> (LogIndex,Term)
  -- | Latest hash or empty
  lastLogHash :: IORef a -> IO ByteString
  lastLogHash' :: a -> ByteString
  -- | Latest term on log or 'startTerm'
  lastLogTerm :: IORef a -> IO Term
  lastLogTerm' :: a -> Term
  -- | get entries after index to beginning, with limit, for AppendEntries message.
  -- TODO make monadic to get 8000 limit from config.
  getEntriesAfter :: LogIndex -> IORef a -> IO (Seq LogEntry)
  getEntriesAfter' :: LogIndex -> a -> Seq LogEntry
  -- | Recursively hash entries from index to tail.
  updateLogHashesFromIndex :: LogIndex -> IORef a -> IO ()
  -- | Append/hash a single entry
  appendLogEntry :: NewLogEntries -> IORef a -> IO ()
  -- | Add/hash entries at specified index.
  addLogEntriesAt :: ReplicateLogEntries -> IORef a -> IO ()
  -- | Update Commit Index
  updateCommitIndex :: UpdateCommitIndex -> IORef a -> IO ()

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

initLogState :: IO (IORef (LogState LogEntry))
initLogState = newIORef $ LogState
  { _logEntries = mempty
  , _lastApplied = startIndex
  , _lastLogIndex = startIndex
  , _nextLogIndex = startIndex + 1
  , _commitIndex = startIndex
  }

instance LogApi (LogState LogEntry) where
  viewLogState l ref = readIORef ref >>= return . view l
  updateLogState f ref = atomicModifyIORef' ref (\ls -> (f ls,()))

  firstEntry ref = readIORef ref >>= return . firstEntry'
  firstEntry' ls = case viewLogs ls of
    (e :< _) -> Just e
    _        -> Nothing

  lastEntry ref = lastEntry' <$> readIORef ref
  lastEntry' ls = case viewLogs ls of
    (_ :> e) -> Just e
    _        -> Nothing

  maxIndex ref = readIORef ref >>= return . maxIndex'
  maxIndex' ls = maybe startIndex _leLogIndex (lastEntry' ls)

  entryCount ref = readIORef ref >>= return . entryCount'
  entryCount' ls = fromIntegral . Seq.length . viewLogSeq $ ls

  lookupEntry i ref = lookupEntry' i <$> readIORef ref
  lookupEntry' i = firstOf (ix i) . viewLogs

  takeEntries t ref = readIORef ref >>= return . takeEntries' t
  takeEntries' t ls = case Seq.take (fromIntegral t) $ viewLogSeq ls of
    v | Seq.null v -> Nothing
      | otherwise  -> Just v

  logInfoForNextIndex' Nothing          _  = (startIndex, startTerm)
  logInfoForNextIndex' (Just myNextIdx) ls = let pli = myNextIdx - 1 in
    case lookupEntry' pli ls of
          Just LogEntry{..} -> (pli, _leTerm)
          -- this shouldn't happen, because nextIndex - 1 should always be at
          -- most our last entry
          Nothing -> (startIndex, startTerm)
  logInfoForNextIndex Nothing          _ = return (startIndex, startTerm)
  logInfoForNextIndex mni ref = readIORef ref >>= return . logInfoForNextIndex' mni

  lastLogHash ref = readIORef ref >>= return . lastLogHash'
  lastLogHash' = maybe mempty _leHash . lastEntry'

  lastLogTerm ref = readIORef ref >>= return . lastLogTerm'
  lastLogTerm' ls = maybe startTerm _leTerm $ lastEntry' ls

  getEntriesAfter pli ref = readIORef ref >>= return . getEntriesAfter' pli
  getEntriesAfter' pli = Seq.take 8000 . Seq.drop (fromIntegral $ pli + 1) . viewLogSeq

  updateLogHashesFromIndex i ref = atomicModifyIORef' ref (\ls ->
    case lookupEntry' i ls of
      Just _ -> (ls {_logEntries = updateLogHashesFromIndex' i $ _logEntries ls}
                ,())
      Nothing -> (ls,())
    )

  -- TODO: this needs to handle picking the right LogIndex
  appendLogEntry le ref = atomicModifyIORef' ref (\ls -> (appendLogEntry' le ls, ()))

  addLogEntriesAt ReplicateLogEntries{..} ref = atomicModifyIORef' ref (\ls -> (addLogEntriesAt' _rlePrvLogIdx _rleEntries ls,()))

  updateCommitIndex UpdateCommitIndex{..} ref = atomicModifyIORef' ref (\ls -> (ls {_commitIndex = _uci},()))


addLogEntriesAt' :: LogIndex -> Seq LogEntry -> LogState LogEntry -> LogState LogEntry
addLogEntriesAt' pli newLEs ls =
  let ls' = updateLogHashesFromIndex' (pli + 1)
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
appendLogEntry' :: NewLogEntries -> LogState LogEntry -> LogState LogEntry
appendLogEntry' NewLogEntries{..} ls = case lastEntry' ls of
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

updateLogHashesFromIndex' :: LogIndex -> Log LogEntry -> Log LogEntry
updateLogHashesFromIndex' i ls =
  case firstOf (ix i) ls of
    Just _ -> updateLogHashesFromIndex' (succ i) $
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
