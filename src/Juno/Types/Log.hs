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
  , LogEntries(..), logEntries, lesCnt, lesMinEntry, lesMaxEntry
  , lesMinIndex, lesMaxIndex, lesEmpty, lesNull, checkLogEntries, lesGetSection
  , lesUnion
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

import Juno.Types.Base
import Juno.Types.Config
import Juno.Types.Message.Signed
import Juno.Types.Message.CMD

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

lesCnt :: LogEntries -> Int
lesCnt (LogEntries les) = Map.size les

lesEmpty :: LogEntries
lesEmpty = LogEntries Map.empty

lesMinEntry :: LogEntries -> Maybe LogEntry
lesMinEntry (LogEntries les) = if Map.null les then Nothing else Just $ snd $ Map.findMin les

lesMaxEntry :: LogEntries -> Maybe LogEntry
lesMaxEntry (LogEntries les) = if Map.null les then Nothing else Just $ snd $ Map.findMax les

lesMinIndex :: LogEntries -> Maybe LogIndex
lesMinIndex (LogEntries les) = if Map.null les then Nothing else Just $ fst $ Map.findMin les

lesMaxIndex :: LogEntries -> Maybe LogIndex
lesMaxIndex (LogEntries les) = if Map.null les then Nothing else Just $ fst $ Map.findMax les

lesGetSection :: Maybe LogIndex -> Maybe LogIndex -> LogEntries -> LogEntries
lesGetSection (Just minIdx) (Just maxIdx) (LogEntries les) = LogEntries $! Map.filterWithKey (\k _ -> k >= minIdx && k <= maxIdx) les
lesGetSection Nothing (Just maxIdx) (LogEntries les) = LogEntries $! Map.filterWithKey (\k _ -> k <= maxIdx) les
lesGetSection (Just minIdx) Nothing (LogEntries les) = LogEntries $! Map.filterWithKey (\k _ -> k >= minIdx) les
lesGetSection Nothing Nothing (LogEntries _) = error "Invariant Error: lesGetSection called with neither a min or max bound!"

lesUnion :: LogEntries -> LogEntries -> LogEntries
lesUnion (LogEntries les1) (LogEntries les2) = LogEntries $! Map.union les1 les2

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
  ULCommitIdx UpdateCommitIndex |
  UpdateLastApplied LogIndex |
  UpdateVerified VerifiedLogEntries
  deriving (Show, Eq, Generic)
