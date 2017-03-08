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

import qualified Data.HashSet as HashSet

import Data.BloomFilter (Bloom)
import qualified Data.BloomFilter as Bloom
import Data.Maybe (isJust)
import Data.Either (partitionEithers)

import Kadena.Types hiding (nodeRole, cmdBloomFilter)
import Kadena.Consensus.Util
import qualified Kadena.Types as KD

import qualified Kadena.Sender.Service as Sender
import qualified Kadena.Evidence.Service as Ev

data CommandEnv = CommandEnv
  { _nodeRole :: Role
  , _cmdBloomFilter :: Bloom RequestKey
  }
makeLenses ''CommandEnv

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

filterBatch :: Bloom RequestKey -> [Command] -> BatchProcessing
filterBatch bfilter cs = BatchProcessing (BPNewEntries brandNew) (BPAlreadySeen likelySeen)
  where
    probablyAlreadySaw cmd@SmartContractCommand{..} =
      -- forcing the inside of an either is notoriously hard. in' is trying to at least force the majority of the work
      let in' = Bloom.elem (toRequestKey cmd) bfilter
          res = if in'
            then Left cmd
            else Right cmd
      in in' `seq` res
    (likelySeen, brandNew) = partitionEithers $! ((probablyAlreadySaw <$> cs) `using` parListN 100 rseq)
{-# INLINE filterBatch #-}

handleCommandBatch :: (MonadReader CommandEnv m,MonadWriter [String] m) => [Command] -> m CommandBatchOut
handleCommandBatch cmdbBatch = do
  tell ["got a command RPC"]
  r <- view nodeRole
  bloom <- view cmdBloomFilter
  return $! case r of
    Leader -> IAmLeader $ filterBatch bloom cmdbBatch
    Follower -> IAmFollower $ filterBatch bloom cmdbBatch
    Candidate -> IAmCandidate

handleBatch :: [Command] -> KD.Consensus ()
handleBatch cmdbBatch = do
  debug "Received Command Batch"
  s <- get
  lid <- return $ KD._currentLeader s
  (out,_) <- runReaderT (runWriterT (handleCommandBatch cmdbBatch)) $
             CommandEnv (KD._nodeRole s)
                        (KD._cmdBloomFilter s)
  debug "Finished processing command batch"
  recAt <- now
  case out of
    IAmLeader BatchProcessing{..} -> do
      updateLogs $ ULNew $ NewLogEntries (KD._term s) (KD.NleEntries $  _unBPNewEntries newEntries) (Just $ ReceivedAt recAt)
      unless (null $ _unBPNewEntries newEntries) $ do
        enqueueRequest $ Sender.BroadcastAE Sender.OnlySendIfFollowersAreInSync
        enqueueRequest $ Sender.BroadcastAER
      -- Bloom filters can give false positives but most of the time the commands will be new, so we do a second pass to double check
      unless (null $ _unBPAlreadySeen alreadySeen) $ do
        -- but we can skip it if we have no collisions... it's the whole point of using the filter
        start <- now
        setOfAlreadySeen <- return $! HashSet.fromList $ toRequestKey <$> _unBPAlreadySeen alreadySeen
        truePositives <- queryHistoryForExisting setOfAlreadySeen
        falsePositive <- return $! HashSet.difference setOfAlreadySeen truePositives
        falsePositiveCommands <- return $! filter (\c' -> HashSet.member (toRequestKey c') falsePositive) $ _unBPAlreadySeen alreadySeen
        end <- now
        unless (HashSet.null falsePositive) $ do
          updateLogs $ ULNew $ NewLogEntries (KD._term s) (KD.NleEntries falsePositiveCommands) (Just $ ReceivedAt recAt)
          enqueueRequest $ Sender.BroadcastAE Sender.OnlySendIfFollowersAreInSync
          enqueueRequest $ Sender.BroadcastAER
          debug $ "CMDB - False positives found "
                  ++ show (HashSet.size falsePositive)
                  ++ " of " ++ show (HashSet.size setOfAlreadySeen) ++ " collisions ("
                  ++ show (interval start end) ++ "mics)"
        sendHistoryNewKeys $ HashSet.union falsePositive $ HashSet.fromList $ toRequestKey <$> _unBPAlreadySeen alreadySeen
      -- the false positives we already collisions so no need to add them
      KD.cmdBloomFilter .= updateBloom newEntries (KD._cmdBloomFilter s)
      quorumSize' <- view KD.quorumSize
      es <- view KD.evidenceState >>= liftIO
      when (Sender.willBroadcastAE quorumSize' (es ^. Ev.pesNodeStates) (es ^. Ev.pesConvincedNodes)) resetHeartbeatTimer
    IAmFollower BatchProcessing{..} -> do
      when (isJust lid) $ do
        enqueueRequest' $ Sender.ForwardCommandToLeader $ NewCmdRPC (encodeCommand <$> _unBPNewEntries newEntries) NewMsg
      unless (null $ _unBPAlreadySeen alreadySeen) $ do
        start <- now
        setOfAlreadySeen <- return $! HashSet.fromList $ toRequestKey <$> _unBPAlreadySeen alreadySeen
        truePositives <- queryHistoryForExisting setOfAlreadySeen
        falsePositive <- return $! HashSet.difference setOfAlreadySeen truePositives
        end <- now
        unless (HashSet.null falsePositive) $ do
          falsePositiveCommands <- return $! filter (\c' -> HashSet.member (toRequestKey c') falsePositive) $ _unBPAlreadySeen alreadySeen
          enqueueRequest' $ Sender.ForwardCommandToLeader $ NewCmdRPC (encodeCommand <$> falsePositiveCommands) NewMsg
          debug $ "CMDB - False positives found "
                  ++ show (HashSet.size falsePositive)
                  ++ " of " ++ show (HashSet.size setOfAlreadySeen) ++ " collisions ("
                  ++ show (interval start end) ++ "mics)"
    IAmCandidate -> return () -- TODO: we should probably respond with something like "availability event"

updateBloom :: BPNewEntries -> Bloom RequestKey -> Bloom RequestKey
updateBloom (BPNewEntries firstPass) oldBloom = Bloom.insertList (toRequestKey <$> firstPass) oldBloom
{-# INLINE updateBloom #-}
