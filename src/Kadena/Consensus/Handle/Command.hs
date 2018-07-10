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
import Data.Thyme.Clock
import Data.Either (partitionEithers)

import Kadena.Command
import qualified Kadena.Config.TMVar as TMV
import Kadena.Types
import Kadena.Consensus.Util
import qualified Kadena.Types as KD
import qualified Kadena.Sender.Service as Sender
import qualified Kadena.Evidence.Types as Ev

data CommandEnv = CommandEnv
  { _nodeRole :: Role
  , _cmdBloomFilter :: Bloom RequestKey
  }
makeLenses ''CommandEnv

newtype BPNewEntries = BPNewEntries { _unBPNewEntries :: [(Maybe CmdLatencyMetrics, Command)]} deriving (Eq, Show)
newtype BPAlreadySeen = BPAlreadySeen { _unBPAlreadySeen :: [(Maybe CmdLatencyMetrics, Command)]} deriving (Eq, Show)

data BatchProcessing = BatchProcessing
  { newEntries :: !BPNewEntries
  , alreadySeen :: !BPAlreadySeen
  } deriving (Show, Eq)

data CommandBatchOut =
  IAmLeader BatchProcessing |
  IAmFollower BatchProcessing |
  IAmCandidate

filterBatch :: Bloom RequestKey -> [(Maybe CmdLatencyMetrics, Command)] -> BatchProcessing
filterBatch bfilter cs = BatchProcessing (BPNewEntries brandNew) (BPAlreadySeen likelySeen)
  where
    probablyAlreadySaw (mLat, cmd) =
      -- forcing the inside of an either is notoriously hard. in' is trying to at least force the majority of the work
      let in' = Bloom.elem (toRequestKey cmd) bfilter
          res = if in'
            then Left (mLat, cmd)
            else Right (mLat, cmd)
      in in' `seq` res
    (likelySeen, brandNew) = partitionEithers $! ((probablyAlreadySaw <$> cs) `using` parListN 100 rseq)
{-# INLINE filterBatch #-}

handleCommandBatch :: (MonadReader CommandEnv m,MonadWriter [String] m) => [(Maybe CmdLatencyMetrics, Command)] -> m CommandBatchOut
handleCommandBatch cmdbBatch = do
  tell ["got a command RPC"]
  r <- view nodeRole
  bloom <- view cmdBloomFilter
  return $! case r of
    Leader -> IAmLeader $ filterBatch bloom cmdbBatch
    Follower -> IAmFollower $ filterBatch bloom cmdbBatch
    Candidate -> IAmCandidate

handleBatch :: [(Maybe CmdLatencyMetrics, Command)] -> KD.Consensus ()
handleBatch cmdbBatch = do
  start' <- now
  debug "Received Command Batch"
  s <- get
  lid <- return $ _csCurrentLeader s
  (out,_) <- runReaderT (runWriterT (handleCommandBatch cmdbBatch)) $
             CommandEnv (_csNodeRole s)
                        (_csCmdBloomFilter s)
  debug "Finished processing command batch"
  case out of
    IAmLeader BatchProcessing{..} -> do
      end' <- now
      updateLogs $ ULNew $ NewLogEntries (_csTerm s) (KD.NleEntries $ updateCmdLat start' end' $ _unBPNewEntries newEntries)
      unless (null $ _unBPNewEntries newEntries) $ do
        enqueueRequest $ Sender.BroadcastAE Sender.OnlySendIfFollowersAreInSync
      -- Bloom filters can give false positives but most of the time the commands will be new, so we do a second pass to double check
      unless (null $ _unBPAlreadySeen alreadySeen) $ do
        -- but we can skip it if we have no collisions... it's the whole point of using the filter
        start <- now
        setOfAlreadySeen <- return $! HashSet.fromList $ toRequestKey . snd <$> _unBPAlreadySeen alreadySeen
        truePositives <- queryHistoryForExisting setOfAlreadySeen
        falsePositive <- return $! HashSet.difference setOfAlreadySeen truePositives
        falsePositiveCommands <- return $! filter (\c' -> HashSet.member (toRequestKey $ snd c') falsePositive) $ _unBPAlreadySeen alreadySeen
        end <- now
        unless (HashSet.null falsePositive) $ do
          updateLogs $ ULNew $ NewLogEntries (_csTerm s) (KD.NleEntries $ updateCmdLat start' end $ falsePositiveCommands)
          enqueueRequest $ Sender.BroadcastAE Sender.OnlySendIfFollowersAreInSync
          debug $ "CMDB - False positives found "
                  ++ show (HashSet.size falsePositive)
                  ++ " of " ++ show (HashSet.size setOfAlreadySeen) ++ " collisions "
                  ++ "(" ++ printInterval start end ++ ")"
        sendHistoryNewKeys $ HashSet.union falsePositive $ HashSet.fromList $ toRequestKey . snd <$> _unBPAlreadySeen alreadySeen
      -- the false positives we already collisions so no need to add them
      csCmdBloomFilter .= updateBloom newEntries (_csCmdBloomFilter s)
      es <- view KD.evidenceState >>= liftIO
      gConfig <- view cfg
      theCfg <- liftIO $ TMV.readCurrentConfig gConfig
      let willBroadcast = Sender.willBroadcastAE (TMV._clusterMembers theCfg)
                                                 (es ^. Ev.pesNodeStates)
                                                 (es ^. Ev.pesConvincedNodes)
                                                 (TMV._nodeId theCfg)
      when willBroadcast
        resetHeartbeatTimer
    IAmFollower BatchProcessing{..} -> do
      when (isJust lid) $
        enqueueRequest' $ Sender.ForwardCommandToLeader $ NewCmdRPC (encodeCommand . snd <$> _unBPNewEntries newEntries) NewMsg
      unless (null $ _unBPAlreadySeen alreadySeen) $ do
        start <- now
        setOfAlreadySeen <- return $! HashSet.fromList $ toRequestKey . snd <$> _unBPAlreadySeen alreadySeen
        truePositives <- queryHistoryForExisting setOfAlreadySeen
        falsePositive <- return $! HashSet.difference setOfAlreadySeen truePositives
        end <- now
        unless (HashSet.null falsePositive) $ do
          falsePositiveCommands <- return $! filter (\c' -> HashSet.member (toRequestKey $ snd c') falsePositive) $ _unBPAlreadySeen alreadySeen
          enqueueRequest' $ Sender.ForwardCommandToLeader $ NewCmdRPC (encodeCommand . snd <$> falsePositiveCommands) NewMsg
          debug $ "CMDB - False positives found "
                  ++ show (HashSet.size falsePositive)
                  ++ " of " ++ show (HashSet.size setOfAlreadySeen) ++ " collisions "
                  ++ "(" ++ printInterval start end ++ ")"
    IAmCandidate -> return () -- TODO: we should probably respond with something like "availability event"

updateBloom :: BPNewEntries -> Bloom RequestKey -> Bloom RequestKey
updateBloom (BPNewEntries firstPass) oldBloom = Bloom.insertList (toRequestKey . snd <$> firstPass) oldBloom
{-# INLINE updateBloom #-}

updateCmdLat :: UTCTime -> UTCTime -> [(Maybe CmdLatencyMetrics, Command)] -> [(Maybe CmdLatencyMetrics, Command)]
updateCmdLat hitCon finCon = fmap (\(mLat, cmd) -> (updateLat mLat, cmd))
  where
    updateLat Nothing = Nothing
    updateLat (Just l) = Just $ l { _lmHitConsensus = Just hitCon
                                  , _lmFinConsensus = Just finCon}
{-# INLINE updateCmdLat #-}
