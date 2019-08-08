{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Log
  ( lesCnt, lesMinEntry, lesMaxEntry, lesMinIndex, lesMaxIndex, lesNull
  , checkLogEntries, lesGetSection  
  , lesUnion, lesUnions, lesLookupEntry, lesUpdateCmdLat
  , plesCnt, plesMinEntry, plesMaxEntry, plesMinIndex, plesMaxIndex, plesNull, plesGetSection
  , plesAddNew, plesLookupEntry, plesTakeTopEntries
  , encodeLEWire, decodeLEWire, decodeLEWire', toLogEntries
  , toReplicateLogEntries
  , verifyLogEntry, verifySeqLogEntries
  , preprocLogEntries, preprocLogEntry
  , hashLogEntry
  ) where

import Control.Lens hiding (Index, (|>))
import Control.Monad
import Control.Parallel.Strategies

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Foldable

import Data.Serialize hiding (get)

import Data.Thyme.Time.Core ()
import Data.Thyme.Clock

import Kadena.Types.Base
import Kadena.Command
import Kadena.Types.Command
import Kadena.Types.Log

preprocLogEntry :: LogEntry -> IO (LogEntry, Maybe RunPreProc)
preprocLogEntry le@LogEntry{..} = do
  (newCmd, rpp) <- prepPreprocCommand _leCommand
  return $ (le { _leCommand = newCmd }, rpp)
{-# INLINE preprocLogEntry #-}

preprocLogEntries :: LogEntries -> IO (LogEntries, Map LogIndex RunPreProc)
preprocLogEntries LogEntries{..} = do
  let les = Map.toAscList _logEntries
      prep (k, le) = (,) <$> pure k <*> preprocLogEntry le
      reinsert (k,(le,rpp)) (les', rpps') =
        (Map.insert k le les', case rpp of
            Nothing -> rpps'
            Just rpp' -> Map.insert k rpp' rpps')
  (newLes, newRpps) <- foldr' reinsert (Map.empty, Map.empty) <$> forM les prep
  return $ (LogEntries newLes, newRpps)
{-# INLINE preprocLogEntries #-}

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

lesUpdateCmdLat :: CmdLatASetter a -> UTCTime -> LogEntries -> LogEntries
lesUpdateCmdLat l t LogEntries{..} = LogEntries $! (over leCmdLatMetrics (populateCmdLat l t)) <$> _logEntries
{-# INLINE lesUpdateCmdLat #-}

plesNull :: PersistedLogEntries -> Bool
plesNull (PersistedLogEntries les) = Map.null les
{-# INLINE plesNull #-}

plesCnt :: PersistedLogEntries -> Int
plesCnt (PersistedLogEntries les) = sum (lesCnt <$> les)
{-# INLINE plesCnt #-}

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

-- TODO: kill tiny crypto worker flow once PreProc Worker is done
verifyLogEntry :: LogEntry -> (Int, Command)
verifyLogEntry LogEntry{..} = res `seq` res
  where
    res = (fromIntegral _leLogIndex, v `seq` v)
    v = verifyCommandIfNotPending _leCommand
{-# INLINE verifyLogEntry #-}

verifySeqLogEntries :: LogEntries -> IntMap Command
verifySeqLogEntries !s = foldr' (\(k,v) -> IntMap.insert k v) IntMap.empty $! ((verifyLogEntry <$> (_logEntries s)) `using` parTraversable rseq)
{-# INLINE verifySeqLogEntries #-}

decodeLEWire' :: Maybe ReceivedAt -> LEWire -> LogEntry
decodeLEWire' !ts (LEWire !(t,i,cmd,hsh)) = LogEntry t i (decodeCommand cmd) hsh (initCmdLat ts)
{-# INLINE decodeLEWire' #-}

insertOrError :: LogEntry -> LogEntry -> LogEntry
insertOrError old new = error $ "Invariant Failure: duplicate LogEntry found!\n Old: " ++ (show old) ++ "\n New: " ++ (show new)

toLogEntries :: [LogEntry] -> LogEntries
toLogEntries !ele = go ele Map.empty
  where
    go [] s = LogEntries s
    go (le:les) s = go les $! Map.insertWith insertOrError (_leLogIndex le) le s
{-# INLINE toLogEntries #-}

decodeLEWire :: Maybe ReceivedAt -> [LEWire] -> Either String LogEntries
decodeLEWire !ts !les = go les Map.empty
  where
    go [] s = Right $! LogEntries s
    go (l:ls) v =
      let logEntry'@LogEntry{..} = decodeLEWire' ts l
      in go ls $! Map.insertWith insertOrError _leLogIndex logEntry' v
{-# INLINE decodeLEWire #-}

encodeLEWire :: LogEntries -> [LEWire]
encodeLEWire les =
  (\LogEntry{..} -> LEWire (_leTerm, _leLogIndex, encodeCommand _leCommand, _leHash)) <$> Map.elems (_logEntries les)
{-# INLINE encodeLEWire #-}

-- TODO: This uses the old decode encode trick and should be changed...
hashLogEntry :: Maybe Hash -> LogEntry -> LogEntry
hashLogEntry (Just prevHash) le@LogEntry{..} =
  le { _leHash = hash (encode $ (_leTerm, _leLogIndex, getCmdBodyHash _leCommand, prevHash))}
hashLogEntry Nothing le@LogEntry{..} =
  le { _leHash = hash (encode $ (_leTerm, _leLogIndex, getCmdBodyHash _leCommand, initialHash))}
{-# INLINE hashLogEntry #-}

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