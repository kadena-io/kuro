{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Kadena.Consensus.Handle.Command
    (handleBatch)
    where

import Control.Lens
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import Control.Parallel.Strategies


import qualified Data.Set as Set



import Data.BloomFilter (Bloom)
import qualified Data.BloomFilter as Bloom
import Data.Maybe (isNothing, isJust, fromJust)
import Data.Either (partitionEithers)

import Kadena.Consensus.Handle.Types
import Kadena.Consensus.Util
import qualified Kadena.Types as KD

import qualified Kadena.Sender.Service as Sender
import qualified Kadena.Evidence.Service as Ev

data CommandEnv = CommandEnv {
      _nodeRole :: Role
    , _term :: Term
    , _currentLeader :: Maybe NodeId
    , _nodeId :: NodeId
    , _cmdBloomFilter :: Bloom RequestKey
}
makeLenses ''CommandEnv

data CommandOut =
    UnknownLeader |
    RetransmitToLeader { _leaderId :: NodeId } |
    CommitAndPropagate {
      _newEntry :: NewLogEntries
    , _replayKey :: RequestKey
    } |
    AlreadySeen

newtype BPNewEntries = BPNewEntries { _unBPNewEntries :: [Command]} deriving (Eq, Show)
newtype BPAlreadySeen = BPAlreadySeen { _unBPAlreadySeen :: [Command]} deriving (Eq, Show)

data BatchProcessing = BatchProcessing
  { newEntries :: !BPNewEntries
  , alreadySeen :: !BPAlreadySeen
  } deriving (Show, Eq)

data CommandBatchOut =
  IAmLeader BatchProcessing |
  IAmFollower BatchProcessing |
  IAmCandidate

filterBatch :: Bloom RequestKey -> Commands -> BatchProcessing
filterBatch bfilter (Commands cs) = BatchProcessing (BPNewEntries brandNew) (BPAlreadySeen likelySeen)
  where
    probablyAlreadySaw cmd@Command{..} =
      -- forcing the inside of an either is notoriously hard. in' is trying to at least force the majority of the work
      let in' = Bloom.elem (toRequestKey "filterBatch" cmd) bfilter
          res = if in'
            then Left cmd
            else Right cmd
      in in' `seq` res
    (likelySeen, brandNew) = partitionEithers $! ((probablyAlreadySaw <$> cs) `using` parListN 100 rseq)
{-# INLINE filterBatch #-}

handleCommandBatch :: (MonadReader CommandEnv m,MonadWriter [String] m) => Commands -> m CommandBatchOut
handleCommandBatch cmdbBatch = do
  tell ["got a command RPC"]
  r <- view nodeRole
  bloom <- view cmdBloomFilter
  return $! case r of
    Leader -> IAmLeader $ filterBatch bloom cmdbBatch
    Follower -> IAmFollower $ filterBatch bloom cmdbBatch
    Candidate -> IAmCandidate

handleBatch :: Commands -> KD.Consensus ()
handleBatch cmdbBatch = do
  debug "Received Command Batch"
  c <- KD.readConfig
  s <- get
  lid <- return $ KD._currentLeader s
  ct <- return $ KD._term s
  (out,_) <- runReaderT (runWriterT (handleCommandBatch cmdbBatch)) $
             CommandEnv (KD._nodeRole s)
                        ct
                        lid
                        (KD._nodeId c)
                        (KD._cmdBloomFilter s)
  debug "Finished processing command batch"
  case out of
    IAmLeader BatchProcessing{..} -> do
      updateLogs $ ULNew $ NewLogEntries (KD._term s) $ KD.NleEntries $  _unBPNewEntries newEntries
      unless (null $ _unBPNewEntries newEntries) $ do
        enqueueRequest $ Sender.BroadcastAE Sender.OnlySendIfFollowersAreInSync
        enqueueRequest $ Sender.BroadcastAER
      -- Bloom filters can give false positives but most of the time the commands will be new, so we do a second pass to double check
      setOfAlreadySeen <- return $! Set.fromList $ toRequestKey "handleBatch.Leader.1" <$> _unBPAlreadySeen alreadySeen
      truePositives <- queryHistoryForExisting setOfAlreadySeen
      falsePositive <- return $! Set.difference setOfAlreadySeen truePositives
      falsePositiveCommands <- return $! filter (\c' -> Set.member (toRequestKey "handleBatch.Leader.2" c') falsePositive) $ _unBPAlreadySeen alreadySeen
      unless (Set.null falsePositive) $ do
        updateLogs $ ULNew $ NewLogEntries (KD._term s) $ KD.NleEntries falsePositiveCommands
        enqueueRequest $ Sender.BroadcastAE Sender.OnlySendIfFollowersAreInSync
        enqueueRequest $ Sender.BroadcastAER
      -- the false positives we already collisions so no need to add them
      KD.cmdBloomFilter .= updateBloom newEntries (KD._cmdBloomFilter s)
      quorumSize' <- view KD.quorumSize
      es <- view KD.evidenceState >>= liftIO
      when (Sender.willBroadcastAE quorumSize' (es ^. Ev.pesNodeStates) (es ^. Ev.pesConvincedNodes)) resetHeartbeatTimer
      sendHistoryNewKeys $ Set.union falsePositive $ Set.fromList $ toRequestKey "handleBatch.Leader.3" <$> _unBPAlreadySeen alreadySeen
    IAmFollower BatchProcessing{..} -> do
      when (isJust lid) $ do
        enqueueRequest $ Sender.ForwardCommandToLeader (fromJust lid) $ _unBPNewEntries newEntries
      setOfAlreadySeen <- return $! Set.fromList $ toRequestKey "handleBatch" <$> _unBPAlreadySeen alreadySeen
      truePositives <- queryHistoryForExisting setOfAlreadySeen
      falsePositive <- return $! Set.difference setOfAlreadySeen truePositives
      unless (Set.null falsePositive) $ do
        falsePositiveCommands <- return $! filter (\c' -> Set.member (toRequestKey "handleBatch.Follower" c') falsePositive) $ _unBPAlreadySeen alreadySeen
        enqueueRequest $ Sender.ForwardCommandToLeader (fromJust lid) falsePositiveCommands
    IAmCandidate -> return () -- TODO: we should probably respond with something like "availability event"

updateBloom :: BPNewEntries -> Bloom RequestKey -> Bloom RequestKey
updateBloom (BPNewEntries firstPass) oldBloom = Bloom.insertList (toRequestKey "updateBloom" <$> firstPass) oldBloom
{-# INLINE updateBloom #-}
