{-# LANGUAGE RecordWildCards #-}

module Kadena.Log.LogApi
  ( lookupEntry
  , getUnappliedEntries
  , getUncommitedHashes
  , getUnpersisted
  , getUnverifiedEntries
  , updateLogs
  , evalQuery
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
import Control.Monad
import Control.Monad.IO.Class

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Serialize hiding (get)

import Kadena.Types.Base
import Kadena.Types.Service.Log
import qualified Kadena.Types.Service.Log as X
import Kadena.Types.Message.Signed
import Kadena.Types.Message.CMD
import Kadena.Log.Persistence

lastPersisted :: LogThread LogIndex
lastPersisted = use lsLastPersisted
{-# INLINE lastPersisted #-}

lastApplied :: LogThread LogIndex
lastApplied = use lsLastApplied
{-# INLINE lastApplied #-}

lastLogIndex :: LogThread LogIndex
lastLogIndex = use lsLastLogIndex
{-# INLINE lastLogIndex #-}

nextLogIndex :: LogThread LogIndex
nextLogIndex = use lsNextLogIndex
{-# INLINE nextLogIndex #-}

commitIndex :: LogThread LogIndex
commitIndex = use lsCommitIndex
{-# INLINE commitIndex #-}

-- | Get the first entry
firstEntry :: LogThread (Maybe LogEntry)
firstEntry = do
  lim <- use lsLastInMemory
  case lim of
    Just lim'
      | lim' >= startIndex -> do
          conn <- view dbConn >>= maybe (error $ "Invariant Error in firstEntry: dbConn was Nothing but lim was " ++ show lim') return
          liftIO $ selectSpecificLogEntry startIndex conn
    _ -> do
      ples <- use lsPersistedLogEntries
      if not $ plesNull ples
          then return $ plesMinEntry ples
          else lesMinEntry <$> use lsVolatileLogEntries
{-# INLINE firstEntry #-}

-- | Get last entry.
lastEntry :: LogThread (Maybe LogEntry)
lastEntry = do
  vles <- use lsVolatileLogEntries
  if not $ lesNull vles
    then return $! lesMaxEntry vles
    else do
      ples <- use lsPersistedLogEntries
      return $! if not $ plesNull ples
        then plesMaxEntry ples
        else Nothing
{-# INLINE lastEntry #-}

-- | Get largest index in ledger.
maxIndex :: LogThread LogIndex
maxIndex = maybe startIndex _leLogIndex <$> lastEntry
{-# INLINE maxIndex #-}

-- | Get count of entries in ledger.
entryCount :: LogThread Int
entryCount = do
  ples <- use lsPersistedLogEntries
  vles <- use lsVolatileLogEntries
  return $! plesCnt ples + lesCnt vles
{-# INLINE entryCount #-}

-- | Safe index
lookupEntry :: LogIndex -> LogThread (Maybe LogEntry)
lookupEntry i = do
  vles <- use lsVolatileLogEntries
  let lookup' i' (LogEntries les) = Map.lookup i' les
  case lookup' i vles of
    Nothing -> do
      ples <- use (lsPersistedLogEntries.pLogEntries)
      case Map.lookupLE i ples of
        Nothing -> return $ Nothing
        Just (_, ples') -> case lookup' i ples' of
          Nothing -> return $ Nothing
          v -> return $ v
    v -> return $ v
{-# INLINE lookupEntry #-}

-- | called by leaders sending appendEntries.
-- given a replica's nextIndex, get the index and term to send as
-- prevLog(Index/Term)
getUncommitedHashes :: LogThread (Map LogIndex ByteString)
getUncommitedHashes = do
  ci   <- commitIndex
  vles <- use lsVolatileLogEntries
  return $ _leHash <$> _logEntries (lesGetSection (Just $ ci + 1) Nothing vles)
{-# INLINE getUncommitedHashes #-}

-- | get every entry that hasn't been applied yet (betweek LastApplied and CommitIndex)
getUnappliedEntries :: LogThread (Maybe LogEntries)
getUnappliedEntries = do
  lv       <- use lsLastCryptoVerified
  vles     <- use lsVolatileLogEntries
  ci       <- commitIndex
  finalIdx <- return $! if lv > ci then ci else lv
  la       <- lastApplied
  les      <- return $! if la < finalIdx
                        then Just $ lesGetSection (Just $ la + 1) (Just finalIdx) vles
                        else Nothing
  case les of
    Just (LogEntries v) | Map.null v -> return $ Nothing
                        | otherwise  -> return $ Just $ LogEntries v
    Nothing -> return $ Nothing
{-# INLINE getUnappliedEntries #-}

getUnpersisted :: LogThread (Maybe LogEntries)
getUnpersisted = do
  la <- lastApplied
  lp <- lastPersisted
  vles <- use lsVolatileLogEntries
  uples <- return $! lesGetSection (Just $ lp + 1) (Just $ la) vles
  return $ if lp < la
           then if Map.null $ _logEntries uples
                then Nothing
                else Just uples
           else Nothing
{-# INLINE getUnpersisted #-}

getUnverifiedEntries :: LogThread (Maybe LogEntries)
getUnverifiedEntries = do
  lstIndex <- maxIndex
  fstIndex <- use lsLastCryptoVerified
  vles <- use lsVolatileLogEntries
  return $! if fstIndex < lstIndex
            then Just $! lesGetSection (Just $ fstIndex + 1) Nothing vles
            else Nothing
{-# INLINE getUnverifiedEntries #-}

logInfoForNextIndex :: Maybe LogIndex -> LogThread (LogIndex,Term)
logInfoForNextIndex Nothing          = return (startIndex, startTerm)
logInfoForNextIndex (Just myNextIdx) = do
  pli <- return $! myNextIdx - 1
  e <- lookupEntry pli
  return $! case e of
    Just LogEntry{..} -> (pli, _leTerm)
    -- this shouldn't happen, because nextIndex - 1 should always be at
    -- most our last entry
    Nothing -> (startIndex, startTerm)
{-# INLINE logInfoForNextIndex #-}

-- | Latest hash or empty
lastLogHash :: LogThread ByteString
lastLogHash = maybe mempty _leHash <$> lastEntry
{-# INLINE lastLogHash #-}

-- | Latest term on log or 'startTerm'
lastLogTerm :: LogThread Term
lastLogTerm = use lsLastLogTerm
{-# INLINE lastLogTerm #-}

-- | get entries after index to beginning, with limit, for AppendEntries message.
-- TODO make monadic to get 8000 limit from config.
getEntriesAfter :: LogIndex -> Int -> LogThread LogEntries
getEntriesAfter pli cnt = do
  lp <- lastPersisted
  vles <- use lsVolatileLogEntries
  if pli >= lp
  then return $! lesGetSection (Just $ pli + 1) (Just $ pli + fromIntegral cnt) vles
  else do
    ples <- use lsPersistedLogEntries
    firstPart <- return $! plesGetSection (Just $ pli + 1) (Just $ pli + fromIntegral cnt) ples
    return $! lesUnion firstPart (lesGetSection (Just $ pli + 1) (Just $ pli + fromIntegral cnt) vles)
{-# INLINE getEntriesAfter #-}

updateLogs :: UpdateLogs -> LogThread ()
updateLogs (ULNew nle) = appendLogEntry nle
updateLogs (ULReplicate ReplicateLogEntries{..}) = addLogEntriesAt _rlePrvLogIdx _rleEntries
updateLogs (ULCommitIdx UpdateCommitIndex{..}) = lsCommitIndex .= _uci
updateLogs (UpdateLastApplied li) = lsLastApplied .= li
updateLogs (UpdateVerified (VerifiedLogEntries res)) = do
  lsVolatileLogEntries %= applyCryptoVerify' res
  lsLastCryptoVerified .= LogIndex (fst $ IntMap.findMax res)
{-# INLINE updateLogs  #-}

applyCryptoVerify' :: IntMap CryptoVerified -> LogEntries -> LogEntries
applyCryptoVerify' m (LogEntries les) = LogEntries $! fmap (\le@LogEntry{..} -> case IntMap.lookup (fromIntegral $ _leLogIndex) m of
      Nothing -> le
      Just c -> le { _leCommand = _leCommand { _cmdCryptoVerified = c }}
      ) les
{-# INLINE applyCryptoVerify' #-}

addLogEntriesAt :: LogIndex -> LogEntries -> LogThread ()
addLogEntriesAt pli newLEs = do
  preceedingEntry <- lookupEntry pli
  vles <- use lsVolatileLogEntries
  existingEntries <- return $! lesGetSection Nothing (Just pli) vles
  prepedLES <- return $! updateLogEntriesHashes preceedingEntry newLEs
  alreadyStored <- return $! case lesMaxEntry prepedLES of
    -- because incremental hashes, if our "new" ones have the same lastHash as whatever we have saved already, we've already stored the lot of them
    Nothing -> error "Invariant Error: addLogEntriesAt called with an empty replicateLogEntries chunk"
    Just lastLe -> case lesLookupEntry (_leLogIndex lastLe) vles of
      Nothing -> False
      Just ourLastLe -> _leHash ourLastLe == _leHash lastLe
  ls' <- return $! lesUnion prepedLES existingEntries
  (lastIdx',lastTerm',lastHash') <- return $!
    if Map.null $ _logEntries ls'
    then error "Invariant Error: addLogEntries attempted called on an null map!"
    else let e = snd $ Map.findMax (ls' ^. logEntries) in (_leLogIndex e, _leTerm e, _leHash e)
  unless alreadyStored $ do
    lsVolatileLogEntries .= ls'
    lsLastLogIndex .= lastIdx'
    lsLastLogHash .= lastHash'
    lsNextLogIndex .= lastIdx' + 1
    lsLastLogTerm .= lastTerm'
{-# INLINE addLogEntriesAt #-}

-- Since the only node to ever append a log entry is the Leader we can start keeping the logs in sync here
-- TODO: this needs to handle picking the right LogIndex
appendLogEntry :: NewLogEntries -> LogThread ()
appendLogEntry NewLogEntries{..} = do
  lastEntry' <- lastEntry
  nli <- use lsNextLogIndex
  case lastEntry' of
    Just ple -> do
      nle <- return $! newEntriesToLog _nleTerm (_leHash ple) nli _nleEntries
      mLastLog' <- return $! lesMaxEntry nle
      case mLastLog' of
        Nothing -> return ()
        Just lastLog' -> do
          lsVolatileLogEntries %= lesUnion (LogEntries $ _logEntries nle)
          lastIdx' <- return $! _leLogIndex lastLog'
          lsLastLogIndex .= lastIdx'
          lsLastLogHash .= _leHash lastLog'
          lsNextLogIndex .= lastIdx' + 1
          lsLastLogTerm  .= _leTerm lastLog'
    Nothing -> do
      nle <- return $! newEntriesToLog _nleTerm B.empty nli _nleEntries
      mLastLog' <- return $! lesMaxEntry nle
      case mLastLog' of
        Nothing -> return ()
        Just lastLog' -> do
          lsVolatileLogEntries .= nle
          lastIdx' <- return $! _leLogIndex lastLog'
          lsLastLogIndex .= lastIdx'
          lsLastLogHash .= _leHash lastLog'
          lsNextLogIndex .= lastIdx' + 1
          lsLastLogTerm  .= _leTerm lastLog'
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

evalQuery :: AtomicQuery -> LogThread QueryResult
evalQuery GetLastApplied = QrLastApplied <$> lastApplied
evalQuery GetLastLogIndex = QrLastLogIndex <$> lastLogIndex
evalQuery GetNextLogIndex = QrNextLogIndex <$> nextLogIndex
evalQuery GetCommitIndex = QrCommitIndex <$> commitIndex
evalQuery GetFirstEntry = QrFirstEntry <$> firstEntry
evalQuery GetLastEntry = QrLastEntry <$> lastEntry
evalQuery GetMaxIndex = QrMaxIndex <$> maxIndex
evalQuery GetUnappliedEntries = QrUnappliedEntries <$> getUnappliedEntries
evalQuery GetEntryCount = QrEntryCount <$> entryCount
evalQuery (GetSomeEntry li) = QrSomeEntry <$> lookupEntry li
evalQuery (GetLogInfoForNextIndex mli) = QrLogInfoForNextIndex <$> logInfoForNextIndex mli
evalQuery GetLastLogHash = QrLastLogHash <$> lastLogHash
evalQuery GetLastLogTerm = QrLastLogTerm <$> lastLogTerm
evalQuery (GetEntriesAfter li cnt) = QrEntriesAfter <$> getEntriesAfter li cnt
evalQuery (GetInfoAndEntriesAfter mli cnt) = do
  (pli, plt) <- logInfoForNextIndex mli
  es <- getEntriesAfter pli cnt
  return $! QrInfoAndEntriesAfter (pli, plt, es)
{-# INLINE evalQuery #-}
