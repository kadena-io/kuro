{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Kadena.Monitoring.Server
  ( startMonitoring
  ) where

import Data.Text.Encoding (decodeUtf8)

import qualified Data.ByteString.Base64 as B64
import qualified Data.Text as T
import qualified System.Metrics.Label as Label
import qualified System.Metrics.Gauge as Gauge
import qualified System.Metrics.Distribution as Dist
-- import qualified System.Metrics.Prometheus.Ridley as R
-- import qualified System.Metrics.Prometheus.Ridley.Types as R

import Kadena.Config.TMVar
import Kadena.Util.Util (awsDashVar)
import Kadena.Types (Metric(..), LogIndex(..), Term(..), NodeId(..))
import Kadena.Monitoring.EkgMonitor (Server, getLabel, getGauge, getDistribution)

-- TODO: re-implement metrics via elasticsearch & remove this file
startApi :: Config -> IO Server
startApi _config = undefined

{-
startApi :: Config -> IO Server
startApi config = do
  let port = 80 + fromIntegral (config ^. nodeId . to _port)
  server <- forkServer "0.0.0.0" port
  let store = serverMetricStore server
  _ <- mkRegistry store $ port + 256
  return server

mkRegistry :: System.Metrics.Store -> R.Port -> IO ()
mkRegistry store port = do
  let rOptions = R.newOptions [] R.defaultMetrics
  _ <- R.startRidleyWithStore rOptions ["metrics"] port store
  return ()
-}

startMonitoring :: Config -> IO (Metric -> IO ())
startMonitoring config = do
  ekg <- startApi config

  let awsDashVar' = awsDashVar False -- (config ^. enableAwsIntegration)

  -- Consensus
  termGauge <- getGauge "kadena.consensus.term" ekg
  commitIndexGauge <- getGauge "kadena.consensus.commit_index" ekg
  commitPeriodDist <- getDistribution "kadena.consensus.commit_period" ekg
  currentLeaderLabel <- getLabel "kadena.consensus.current_leader" ekg
  hashLabel <- getLabel "kadena.consensus.hash" ekg
  -- Node
  nodeIdLabel <- getLabel "kadena.node.id" ekg
  hostLabel <- getLabel "kadena.node.host" ekg
  portGauge <- getGauge "kadena.node.port" ekg
  roleLabel <- getLabel "kadena.node.role" ekg
  appliedIndexGauge <- getGauge "kadena.node.applied_index" ekg
  applyLatencyDist <- getDistribution "kadena.node.apply_latency" ekg
  -- Cluster, quorum size
  clusterSizeGauge <- getGauge "kadena.cluster.size" ekg
  quorumSizeGauge <- getGauge "kadena.cluster.quorum_size" ekg
  availableSizeGauge <- getGauge "kadena.cluster.available_size" ekg
  -- Cluster configuration change
  changeToClusterSizeGauge <- getGauge "kadena.cluster.change_to_size" ekg
  changeToQuorumSizeGauge <- getGauge "kadena.cluster.change_to_quorum_size" ekg
  -- Cluster membership
  clusterMembersLabel <- getLabel "kadena.cluster.members" ekg

  return $ \case
    -- Consensus
    MetricTerm (Term t) -> do
      Gauge.set termGauge $ fromIntegral t
      awsDashVar' "Term" $ show t
    MetricCommitIndex (LogIndex idx) -> do
      Gauge.set commitIndexGauge $ fromIntegral idx
      awsDashVar' "CommitIndex" $ show idx
    MetricCommitPeriod p ->
      Dist.add commitPeriodDist p
    MetricCurrentLeader mNode ->
      case mNode of
        Just node -> Label.set currentLeaderLabel $ nodeDescription node
        Nothing -> Label.set currentLeaderLabel ""
    MetricHash bs ->
      Label.set hashLabel $ decodeUtf8 $ B64.encode bs
    -- Node
    MetricNodeId node@(NodeId host port _ _) -> do
      Label.set nodeIdLabel $ nodeDescription node
      Label.set hostLabel $ T.pack host
      Gauge.set portGauge $ fromIntegral port
    MetricRole role -> do
      Label.set roleLabel $ T.pack $ show role
      awsDashVar' "Role" $ show role
    MetricAppliedIndex (LogIndex idx) -> do
      Gauge.set appliedIndexGauge $ fromIntegral idx
      awsDashVar' "AppliedIndex" $ show idx
    MetricApplyLatency l ->
      Dist.add applyLatencyDist l
    -- Cluster
    MetricClusterSize size ->
      Gauge.set clusterSizeGauge $ fromIntegral size
    MetricQuorumSize size ->
      Gauge.set quorumSizeGauge $ fromIntegral size
    MetricAvailableSize size ->
      Gauge.set availableSizeGauge $ fromIntegral size
    -- Cluster configuration change
    MetricChangeToClusterSize size ->
      Gauge.set changeToClusterSizeGauge $ fromIntegral size
    MetricChangeToQuorumSize size ->
      Gauge.set changeToQuorumSizeGauge $ fromIntegral size
    MetricClusterMembers members ->
      Label.set clusterMembersLabel members
  where
    nodeDescription :: NodeId -> T.Text
    nodeDescription (NodeId host port _ _) = T.pack $ host ++ ":" ++ show port
