
module Kadena.Types.Metric
  ( Metric(..)
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)

import Kadena.Types.Base

data Metric
  -- Consensus metrics:
  = MetricTerm Term
  | MetricCommitIndex LogIndex
  | MetricCommitPeriod Double          -- For computing throughput
  | MetricCurrentLeader (Maybe NodeId)
  | MetricHash ByteString
  -- Node metrics:
  | MetricNodeId NodeId
  | MetricRole Role
  | MetricAppliedIndex LogIndex
  | MetricApplyLatency Double
  -- Cluster metrics:
  | MetricClusterSize Int
  | MetricQuorumSize Int
  | MetricAvailableSize Int
  | MetricChangeToClusterSize Int -- cluster size after config change
  | MetricChangeToQuorumSize Int -- quorum size after config change
  | MetricClusterMembers Text
