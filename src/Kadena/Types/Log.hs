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
  ( LogEntry(..), leTerm, leLogIndex, leCommand, leHash
  , LogEntries(..), logEntries, lesCnt, lesMinEntry, lesMaxEntry
  , lesMinIndex, lesMaxIndex, lesEmpty, lesNull, checkLogEntries, lesGetSection
  , lesUnion, lesUnions, lesLookupEntry
  , PersistedLogEntries(..), pLogEntries, plesCnt, plesMinEntry, plesMaxEntry
  , plesMinIndex, plesMaxIndex, plesEmpty, plesNull, plesGetSection
  , plesAddNew, plesLookupEntry, plesTakeTopEntries
  , LEWire(..), encodeLEWire, decodeLEWire, decodeLEWire', toLogEntries
  , ReplicateLogEntries(..), rleMinLogIdx, rleMaxLogIdx, rlePrvLogIdx, rleEntries
  , toReplicateLogEntries
  , NewLogEntries(..), nleTerm, nleEntries
  , UpdateCommitIndex(..), uci
  , UpdateLogs(..)
  , hashLogEntry
  , hash
  , VerifiedLogEntries(..)
  , verifyLogEntry, verifySeqLogEntries
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

import Control.Parallel.Strategies
import Control.Lens hiding (Index, (|>))

import qualified Crypto.Hash.BLAKE2.BLAKE2bp as BLAKE

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.ByteString as B
import Data.ByteString (ByteString)
import Data.Serialize hiding (get)
import Data.Foldable

import Data.Thyme.Time.Core ()
import GHC.Generics

import Kadena.Types.Base
import Kadena.Types.Config
import Kadena.Types.Message.Signed
import Kadena.Types.Message.CMD

hash :: ByteString -> ByteString
hash = BLAKE.hash 32 B.empty
{-# INLINE hash #-}

-- TODO: add discrimination here, so we can get a better map construction
data LogEntry = LogEntry
  { _leTerm     :: !Term
  , _leLogIndex :: !LogIndex
  , _leCommand  :: !Command
  , _leHash     :: !ByteString
  }
  deriving (Show, Eq, Ord, Generic)
makeLenses ''LogEntry

data LEWire = LEWire (Term, LogIndex, SignedRPC, ByteString)
  deriving (Show, Generic)
instance Serialize LEWire

newtype LogEntries = LogEntries { _logEntries :: Map LogIndex LogEntry }
    deriving (Eq,Show,Ord,Generic)
makeLenses ''LogEntries

checkLogEntries :: Map LogIndex LogEntry -> Either String LogEntries
checkLogEntries m = if Map.null m
  then Right $ LogEntries m
  else let verifiedMap = Map.filterWithKey (\k a -> k == _leLogIndex a) m
       in verifiedMap `seq` if Map.size m == Map.size verifiedMap
                            then Right $! LogEntries m
                            else Left $! "Mismatches in the map were found!\n" ++ show (Map.difference m verifiedMap)

lesNull :: LogEntries -> Bool
lesNull (LogEntries les) = Map.null les
{-# INLINE lesNull #-}

lesCnt :: LogEntries -> Int
lesCnt (LogEntries les) = Map.size les
{-# INLINE lesCnt #-}

lesEmpty :: LogEntries
lesEmpty = LogEntries Map.empty
{-# INLINE lesEmpty #-}

lesLookupEntry :: LogIndex -> LogEntries -> Maybe LogEntry
lesLookupEntry lIdx (LogEntries les) = Map.lookup lIdx les
{-# INLINE lesLookupEntry #-}

lesMinEntry :: LogEntries -> Maybe LogEntry
lesMinEntry (LogEntries les) = if Map.null les then Nothing else Just $ snd $ Map.findMin les
{-# INLINE lesMinEntry #-}

lesMaxEntry :: LogEntries -> Maybe LogEntry
lesMaxEntry (LogEntries les) = if Map.null les then Nothing else Just $ snd $ Map.findMax les
{-# INLINE lesMaxEntry #-}

lesMinIndex :: LogEntries -> Maybe LogIndex
lesMinIndex (LogEntries les) = if Map.null les then Nothing else Just $ fst $ Map.findMin les
{-# INLINE lesMinIndex #-}

lesMaxIndex :: LogEntries -> Maybe LogIndex
lesMaxIndex (LogEntries les) = if Map.null les then Nothing else Just $ fst $ Map.findMax les
{-# INLINE lesMaxIndex #-}

lesGetSection :: Maybe LogIndex -> Maybe LogIndex -> LogEntries -> LogEntries
lesGetSection (Just minIdx) (Just maxIdx) (LogEntries les) = LogEntries $! Map.filterWithKey (\k _ -> k >= minIdx && k <= maxIdx) les
lesGetSection Nothing (Just maxIdx) (LogEntries les) = LogEntries $! Map.filterWithKey (\k _ -> k <= maxIdx) les
lesGetSection (Just minIdx) Nothing (LogEntries les) = LogEntries $! Map.filterWithKey (\k _ -> k >= minIdx) les
lesGetSection Nothing Nothing (LogEntries _) = error "Invariant Error: lesGetSection called with neither a min or max bound!"
{-# INLINE lesGetSection #-}

lesUnion :: LogEntries -> LogEntries -> LogEntries
lesUnion (LogEntries les1) (LogEntries les2) = LogEntries $! Map.union les1 les2
{-# INLINE lesUnion #-}

lesUnions :: [LogEntries] -> LogEntries
lesUnions les = LogEntries $! (Map.unions (_logEntries <$> les))
{-# INLINE lesUnions #-}

newtype PersistedLogEntries = PersistedLogEntries { _pLogEntries :: Map LogIndex LogEntries }
    deriving (Eq,Show,Ord,Generic)
makeLenses ''PersistedLogEntries

plesNull :: PersistedLogEntries -> Bool
plesNull (PersistedLogEntries les) = Map.null les
{-# INLINE plesNull #-}

plesCnt :: PersistedLogEntries -> Int
plesCnt (PersistedLogEntries les) = sum (lesCnt <$> les)
{-# INLINE plesCnt #-}

plesEmpty :: PersistedLogEntries
plesEmpty = PersistedLogEntries Map.empty
{-# INLINE plesEmpty #-}

plesLookupEntry :: LogIndex -> PersistedLogEntries -> Maybe LogEntry
plesLookupEntry lIdx (PersistedLogEntries ples) = Map.lookupLE lIdx ples >>= lesLookupEntry lIdx . snd

plesMinEntry :: PersistedLogEntries -> Maybe LogEntry
plesMinEntry (PersistedLogEntries les) = if Map.null les then Nothing else lesMinEntry $ snd $ Map.findMin les
{-# INLINE plesMinEntry #-}

plesMaxEntry :: PersistedLogEntries -> Maybe LogEntry
plesMaxEntry (PersistedLogEntries les) = if Map.null les then Nothing else lesMaxEntry $ snd $ Map.findMax les
{-# INLINE plesMaxEntry #-}

plesMinIndex :: PersistedLogEntries -> Maybe LogIndex
plesMinIndex (PersistedLogEntries les) = if Map.null les then Nothing else lesMinIndex $ snd $ Map.findMin les
{-# INLINE plesMinIndex #-}

plesMaxIndex :: PersistedLogEntries -> Maybe LogIndex
plesMaxIndex (PersistedLogEntries les) = if Map.null les then Nothing else lesMaxIndex $ snd $ Map.findMax les
{-# INLINE plesMaxIndex #-}

plesGetSection :: Maybe LogIndex -> Maybe LogIndex -> PersistedLogEntries -> LogEntries
plesGetSection Nothing Nothing (PersistedLogEntries _) = error "Invariant Error: plesGetSection called with neither a min or max bound!"
plesGetSection m1 m2 (PersistedLogEntries les) = lesUnions $ lesGetSection m1 m2 <$> getParts
  where
    firstChunk = maybe Nothing (\idx -> fst <$> Map.lookupLE idx les) m1
    firstAfterLastChunk = maybe Nothing (\idx -> fst <$> Map.lookupGT idx les) m2
    getParts = case (firstChunk, firstAfterLastChunk) of
      (Nothing, Nothing) -> Map.elems les
      (Just fIdx, Nothing) -> Map.elems $ Map.filterWithKey (\k _ -> k >= fIdx) les
      (Just fIdx, Just lIdx) -> Map.elems $ Map.filterWithKey (\k _ -> k >= fIdx && k < lIdx) les
      (Nothing, Just lIdx) -> Map.elems $ Map.filterWithKey (\k _ -> k < lIdx) les
{-# INLINE plesGetSection #-}

-- NB: this is the wrong way to do this, I think it shouldn't be exposed/should be explicitly implemented as needed
--plesUnion :: PersistedLogEntries -> PersistedLogEntries -> PersistedLogEntries
--plesUnion (PersistedLogEntries les1) (PersistedLogEntries les2) = PersistedLogEntries $! Map.union les1 les2
--{-# INLINE plesUnion #-}

plesAddNew :: LogEntries -> PersistedLogEntries -> PersistedLogEntries
plesAddNew les p@(PersistedLogEntries ples) = case lesMinIndex les of
  Nothing -> p
  Just k -> case plesMaxIndex p of
    pk | pk == Nothing || pk <= (Just k) -> PersistedLogEntries $! Map.insertWith (\n o -> lesUnion o n) k les ples
    Just pk -> error $ "Invariant Error: plesAddNew les's minIndex (" ++ show k ++ ") is <= ples's (" ++ show pk ++ ")"
    Nothing -> error $ "plesAddNew: pattern matcher can't introspect guards... I should be impossible to hit"
{-# INLINE plesAddNew #-}

plesTakeTopEntries :: Int -> PersistedLogEntries -> (Maybe LogIndex, PersistedLogEntries)
plesTakeTopEntries atLeast' orig@(PersistedLogEntries ples) =
    case findSplitKey atLeast' sizeCnts of
      Nothing -> (Nothing, orig)
      Just k -> (Just k, PersistedLogEntries $! Map.filterWithKey (\k' _ -> k' >= k) ples)
  where
    sizeCnts :: Map LogIndex Int
    sizeCnts = lesCnt <$> ples
{-# INLINE plesTakeTopEntries #-}

findSplitKey :: (Show k, Eq k, Ord k) => Int -> Map k Int -> Maybe k
findSplitKey atLeast' mapOfCounts =
    if evenBother
    then go 0 $! Map.toDescList mapOfCounts
    else Nothing
  where
    evenBother = atLeast' < sum (Map.elems mapOfCounts)
    go _ [] = error $ "Invariant Error in findSplitKey: somehow we got an empty count list!"
                    ++ "\natLeast: " ++ show atLeast'
                    ++ "\nsizeCnts: " ++ show mapOfCounts
                    ++ "\nples: " ++ show mapOfCounts
    go _ [(k,_)] = Just k
    go cnt ((k,v):rest)
      | cnt + v >= atLeast' = Just k
      | otherwise = go (cnt+v) rest
{-# SPECIALIZE INLINE findSplitKey :: Int -> Map LogIndex Int -> Maybe LogIndex #-}


decodeLEWire' :: Maybe ReceivedAt -> KeySet -> LEWire -> Either String LogEntry
decodeLEWire' !ts !ks (LEWire !(t,i,cmd,hsh)) = case fromWire ts ks cmd of
      Left !err -> Left $!err
      Right !cmd' -> Right $! LogEntry t i cmd' hsh
{-# INLINE decodeLEWire' #-}

insertOrError :: LogEntry -> LogEntry -> LogEntry
insertOrError old new = error $ "Invariant Failure: duplicate LogEntry found!\n Old: " ++ (show old) ++ "\n New: " ++ (show new)

-- TODO: check if `toSeqLogEntry ele = Seq.fromList <$> sequence ele` is fusable?
toLogEntries :: [Either String LogEntry] -> Either String LogEntries
toLogEntries !ele = go ele Map.empty
  where
    go [] s = Right $! LogEntries s
    go (Right le:les) s = go les $! Map.insertWith insertOrError (_leLogIndex le) le s
    go (Left err:_) _ = Left $! err
{-# INLINE toLogEntries #-}

verifyLogEntry :: KeySet -> LogEntry -> (Int, CryptoVerified)
verifyLogEntry !ks LogEntry{..} = res `seq` res
  where
    res = (fromIntegral _leLogIndex, v `seq` v)
    v = verifyCmd ks _leCommand
{-# INLINE verifyLogEntry #-}

verifySeqLogEntries :: KeySet -> LogEntries -> IntMap CryptoVerified
verifySeqLogEntries !ks !s = foldr' (\(k,v) -> IntMap.insert k v) IntMap.empty $! ((verifyLogEntry ks <$> (_logEntries s)) `using` parTraversable rseq)
{-# INLINE verifySeqLogEntries #-}

newtype VerifiedLogEntries = VerifiedLogEntries
  { _vleResults :: (IntMap CryptoVerified)}
  deriving (Show, Eq)

decodeLEWire :: Maybe ReceivedAt -> KeySet -> [LEWire] -> Either String LogEntries
decodeLEWire !ts !ks !les = go les Map.empty
  where
    go [] s = Right $! LogEntries s
    go (LEWire !(t,i,cmd,hsh):ls) v = case fromWire ts ks cmd of
      Left err -> Left $! err
      Right cmd' -> go ls $! Map.insertWith insertOrError i (LogEntry t i cmd' hsh) v
{-# INLINE decodeLEWire #-}

encodeLEWire :: NodeId -> PublicKey -> PrivateKey -> LogEntries -> [LEWire]
encodeLEWire nid pubKey privKey les =
  (\LogEntry{..} -> LEWire (_leTerm, _leLogIndex, toWire nid pubKey privKey _leCommand, _leHash)) <$> (Map.elems $ _logEntries les)
{-# INLINE encodeLEWire #-}

-- TODO: This uses the old decode encode trick and should be changed...
hashLogEntry :: Maybe LogEntry -> LogEntry -> LogEntry
hashLogEntry (Just LogEntry{ _leHash = prevHash }) le@LogEntry{..} =
  le { _leHash = hash (encode $ LEWire (_leTerm, _leLogIndex, getCmdSignedRPC le, prevHash))}
hashLogEntry Nothing le@LogEntry{..} =
  le { _leHash = hash (encode $ LEWire (_leTerm, _leLogIndex, getCmdSignedRPC le, mempty))}
{-# INLINE hashLogEntry #-}

getCmdSignedRPC :: LogEntry -> SignedRPC
getCmdSignedRPC LogEntry{ _leCommand = Command{ _cmdProvenance = ReceivedMsg{ _pDig = dig, _pOrig = bdy }}} =
  SignedRPC dig bdy
getCmdSignedRPC LogEntry{ _leCommand = Command{ _cmdProvenance = NewMsg }} =
  error "Invariant Failure: for a command to be in a log entry, it needs to have been received!"

data ReplicateLogEntries = ReplicateLogEntries
  { _rleMinLogIdx :: LogIndex
  , _rleMaxLogIdx :: LogIndex
  , _rlePrvLogIdx :: LogIndex
  , _rleEntries   :: LogEntries
  } deriving (Show, Eq, Generic)
makeLenses ''ReplicateLogEntries

toReplicateLogEntries :: LogIndex -> LogEntries -> Either String ReplicateLogEntries
toReplicateLogEntries prevLogIndex les = do
  let minLogIdx = fst $! Map.findMin $ _logEntries les
      maxLogIdx = fst $! Map.findMax $ _logEntries les
  if prevLogIndex /= minLogIdx - 1
  then Left $ "PrevLogIndex ("
            ++ show prevLogIndex
            ++ ") should be -1 the head entry's ("
            ++ show minLogIdx
            ++ ")"
  else if fromIntegral (maxLogIdx - minLogIdx + 1) /= (Map.size $ _logEntries les) && maxLogIdx /= startIndex && minLogIdx /= startIndex
  then Left $ "HeadLogIdx - TailLogIdx + 1 != length les: "
            ++ show maxLogIdx
            ++ " - "
            ++ show minLogIdx
            ++ " + 1 != "
            ++ show (Map.size $ _logEntries les)
  else -- TODO: add a protection in here to check that Seq's LogIndexs are
    -- strictly increasing by 1 from right to left
    return $ ReplicateLogEntries { _rleMinLogIdx = minLogIdx
                                 , _rleMaxLogIdx = maxLogIdx
                                 , _rlePrvLogIdx = prevLogIndex
                                 , _rleEntries   = les }

newtype NleEntries = NleEntries { unNleEntries :: [Command] } deriving (Eq,Show)

data NewLogEntries = NewLogEntries
  { _nleTerm :: !Term
  , _nleEntries :: !NleEntries
  } deriving (Show, Eq, Generic)
makeLenses ''NewLogEntries

newtype UpdateCommitIndex = UpdateCommitIndex {_uci :: LogIndex}
  deriving (Show, Eq, Generic)
makeLenses ''UpdateCommitIndex

data UpdateLogs =
  ULReplicate ReplicateLogEntries |
  ULNew NewLogEntries |
  ULCommitIdx UpdateCommitIndex |
  UpdateLastApplied LogIndex |
  UpdateVerified VerifiedLogEntries
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
