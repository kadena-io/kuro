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
  , ReplicateLogEntries(..), rleMinLogIdx, rleMaxLogIdx, rlePrvLogIdx, rleEntries
  , toReplicateLogEntries
  , NewLogEntries(..), nleTerm, nleEntries
  , UpdateCommitIndex(..), uci
  , UpdateLogs(..)
  , hashLogEntry
  , seqHead
  , seqTail
  , hash
  , VerifiedLogEntries(..)
  , verifyLogEntry, verifySeqLogEntries
  ) where

import Control.Parallel.Strategies
import Control.Lens hiding (Index, (|>))
import qualified Control.Lens as Lens

import qualified Crypto.Hash.BLAKE2.BLAKE2bp as BLAKE

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import qualified Data.ByteString as B
import Data.ByteString (ByteString)
import Data.Serialize hiding (get)
import Data.Foldable
import Data.Maybe (fromJust)
import Data.Thyme.Time.Core ()
import GHC.Generics

import Juno.Types.Base
import Juno.Types.Config
import Juno.Types.Message.Signed
import Juno.Types.Message.CMD

hash :: ByteString -> ByteString
hash = BLAKE.hash 32 B.empty
{-# INLINE hash #-}

data LogEntry = LogEntry
  { _leTerm    :: !Term
  , _leLogIndex :: !LogIndex
  , _leCommand :: !Command
  , _leHash    :: !ByteString
  }
  deriving (Show, Eq, Ord, Generic)
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

verifyLogEntry :: KeySet -> LogEntry -> (Int, CryptoVerified)
verifyLogEntry !ks LogEntry{..} = res `seq` res
  where
    res = (fromIntegral _leLogIndex, v `seq` v)
    v = verifyCmd ks _leCommand
{-# INLINE verifyLogEntry #-}

verifySeqLogEntries :: KeySet -> Seq LogEntry -> IntMap CryptoVerified
verifySeqLogEntries !ks !s = foldr' (\(k,v) -> IntMap.insert k v) IntMap.empty $! ((verifyLogEntry ks <$> s) `using` parTraversable rseq)
{-# INLINE verifySeqLogEntries #-}

data VerifiedLogEntries = VerifiedLogEntries
  { _vleMaxIndex :: LogIndex
  , _vleResults :: (IntMap CryptoVerified)}
  deriving (Show, Eq)

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
  , _rleEntries :: Seq LogEntry
  } deriving (Show, Eq, Generic)
makeLenses ''ReplicateLogEntries

seqHead :: Seq a -> Maybe a
seqHead s = case Seq.viewl s of
  (e Seq.:< _) -> Just e
  _            -> Nothing
{-# INLINE seqHead #-}

seqTail :: Seq a -> Maybe a
seqTail s = case Seq.viewr s of
  (_ Seq.:> e) -> Just e
  _        -> Nothing
{-# INLINE seqTail #-}

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
