{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
module Kadena.Consensus.Publish
  ( Publish(..), publish, buildCmdRpc, buildCmdRpcBS
  , buildCCCmdRpc
  , pactBSToCMDWire, pactTextToCMDWire
  , clusterChgBSToCMDWire, clusterChgTextToCMDWire
  ) where

import Control.Concurrent
import Data.Thyme (UTCTime)
import Control.Monad.IO.Class
import Data.Text.Encoding
import qualified Data.Serialize as SZ
import Data.Text (Text)
import Data.ByteString (ByteString)

import Kadena.Types.Spec
import Kadena.Types.Comms
import Kadena.Types.Dispatch
import Kadena.Types.Base
import Kadena.Types.Command
import Kadena.Types.Message
import Kadena.Types.Sender
import Kadena.Util.Util

import Pact.Types.API
import qualified Pact.Types.Command as Pact

data Publish = Publish
  { pConsensus :: MVar PublishedConsensus
  , pDispatch :: Dispatch
  , pNow :: IO UTCTime
  , pNodeId :: NodeId
  }


publish :: MonadIO m => Publish -> (forall a . String -> m a) -> [(RequestKey,CMDWire)] -> m RequestKeys
publish Publish{..} die rpcs = do
  PublishedConsensus{..} <- liftIO (tryReadMVar pConsensus) >>=
    fromMaybeM (die "Invariant error: consensus unavailable")
  ldr <- fromMaybeM
    (die (show pNodeId ++ ": There is no current leader. System unavaiable, please try again later"))
    _pcLeader
  rAt <- ReceivedAt <$> liftIO pNow
  cmds' <- return $! snd <$> rpcs
  rks' <- return $ RequestKeys $! fst <$> rpcs
  if pNodeId == ldr
  then  -- dispatch internally if we're leader, otherwise send outbound
    liftIO $ writeComm (_dispInboundCMD pDispatch) $ InboundCMDFromApi $ (rAt, NewCmdInternal cmds')
  else
    liftIO $ writeComm (_dispSenderService pDispatch) $! ForwardCommandToLeader (NewCmdRPC cmds' NewMsg)
  return rks'

pactBSToCMDWire :: Pact.Command ByteString -> CMDWire
pactBSToCMDWire = SCCWire . SZ.encode

pactTextToCMDWire :: Pact.Command Text -> CMDWire
pactTextToCMDWire cmd = pactBSToCMDWire (encodeUtf8 <$> cmd)

buildCmdRpc :: Pact.Command Text -> (RequestKey,CMDWire)
buildCmdRpc c@Pact.Command{..} = (Pact.cmdToRequestKey c, pactTextToCMDWire c)

buildCmdRpcBS :: Pact.Command ByteString -> (RequestKey,CMDWire)
buildCmdRpcBS c@Pact.Command{..} = (Pact.cmdToRequestKey c, pactBSToCMDWire c)

-- TODO: Try to implment ClusterChangeCommand as Pact.Command ClusterChangeCommand.  If possible,
-- this can be removed in favor of using Pact's buildCmdRpc
buildCCCmdRpc :: ClusterChangeCommand Text -> (RequestKey, CMDWire)
buildCCCmdRpc c@ClusterChangeCommand {..} = (RequestKey _cccHash, clusterChgTextToCMDWire c)

clusterChgTextToCMDWire :: ClusterChangeCommand Text -> CMDWire
clusterChgTextToCMDWire cmd = clusterChgBSToCMDWire (encodeUtf8 <$> cmd)

clusterChgBSToCMDWire :: ClusterChangeCommand ByteString -> CMDWire
clusterChgBSToCMDWire = CCCWire . SZ.encode
