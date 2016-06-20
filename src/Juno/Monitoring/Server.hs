{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Juno.Monitoring.Server
  ( startMonitoring
  ) where

import System.Process (system)

import Control.Monad (void)
import Control.Concurrent (forkIO)
import Control.Lens ((^.), to)
import Data.Text.Encoding (decodeUtf8)

import qualified Data.ByteString.Base64 as B64
import qualified Data.Text as T
import qualified System.Metrics.Label as Label
import qualified System.Metrics.Gauge as Gauge
import qualified System.Metrics.Distribution as Dist

import Juno.Types (Config, nodeId, Metric(..), LogIndex(..), Term(..), NodeID(..), _port)
import Juno.Monitoring.EkgMonitor (Server, forkServer, getLabel, getGauge, getDistribution)

-- TODO: possibly switch to 'newStore' API. this allows us to use groups.

startApi :: Config -> IO Server
startApi config = forkServer "localhost" port
  where
    port = 80 + fromIntegral (config ^. nodeId . to _port)

awsDashVar :: String -> String -> IO ()
awsDashVar k v = void $ forkIO $ void $ system $
  "aws ec2 create-tags --resources `ec2-metadata --instance-id | sed 's/^.*: //g'` --tags Key="
  ++ k
  ++ ",Value="
  ++ v
  ++ " >/dev/null"

startMonitoring :: Config -> IO (Metric -> IO ())
startMonitoring config = do
  ekg <- startApi config

  -- Consensus
  termGauge <- getGauge "juno.consensus.term" ekg
  commitIndexGauge <- getGauge "juno.consensus.commit_index" ekg
  commitPeriodDist <- getDistribution "juno.consensus.commit_period" ekg
  currentLeaderLabel <- getLabel "juno.consensus.current_leader" ekg
  hashLabel <- getLabel "juno.consensus.hash" ekg
  -- Node
  nodeIdLabel <- getLabel "juno.node.id" ekg
  hostLabel <- getLabel "juno.node.host" ekg
  portGauge <- getGauge "juno.node.port" ekg
  roleLabel <- getLabel "juno.node.role" ekg
  appliedIndexGauge <- getGauge "juno.node.applied_index" ekg
  applyLatencyDist <- getDistribution "juno.node.apply_latency" ekg
  -- Cluster
  clusterSizeGauge <- getGauge "juno.cluster.size" ekg
  quorumSizeGauge <- getGauge "juno.cluster.quorum_size" ekg
  availableSizeGauge <- getGauge "juno.cluster.available_size" ekg

  return $ \case
    -- Consensus
    MetricTerm (Term t) -> do
      Gauge.set termGauge $ fromIntegral t
      awsDashVar "Term" $ show t
    MetricCommitIndex (LogIndex idx) -> do
      Gauge.set commitIndexGauge $ fromIntegral idx
      awsDashVar "CommitIndex" $ show idx
    MetricCommitPeriod p ->
      Dist.add commitPeriodDist p
    MetricCurrentLeader mNode ->
      case mNode of
        Just node -> Label.set currentLeaderLabel $ nodeDescription node
        Nothing -> Label.set currentLeaderLabel ""
    MetricHash bs ->
      Label.set hashLabel $ decodeUtf8 $ B64.encode bs
    -- Node
    MetricNodeId node@(NodeID host port _ _) -> do
      Label.set nodeIdLabel $ nodeDescription node
      Label.set hostLabel $ T.pack host
      Gauge.set portGauge $ fromIntegral port
    MetricRole role -> do
      Label.set roleLabel $ T.pack $ show role
      awsDashVar "Role" $ show role
    MetricAppliedIndex (LogIndex idx) -> do
      Gauge.set appliedIndexGauge $ fromIntegral idx
      awsDashVar "AppliedIndex" $ show idx
    MetricApplyLatency l ->
      Dist.add applyLatencyDist l
    -- Cluster
    MetricClusterSize size ->
      Gauge.set clusterSizeGauge $ fromIntegral size
    MetricQuorumSize size ->
      Gauge.set quorumSizeGauge $ fromIntegral size
    MetricAvailableSize size ->
      Gauge.set availableSizeGauge $ fromIntegral size

  where
    nodeDescription :: NodeID -> T.Text
    nodeDescription (NodeID host port _ _) = T.pack $ host ++ ":" ++ show port
