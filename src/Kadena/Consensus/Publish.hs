{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
module Kadena.Consensus.Publish
  ( Publish(..), publish, buildCmdRpc, buildCmdRpcBS
  , buildCCCmdRpc
  , pactBSToCMDWire, pactTextToCMDWire
  , clusterChgBSToCMDWire, clusterChgTextToCMDWire
  ) where

import Control.Concurrent
import Control.Monad.IO.Class

import Data.ByteString (ByteString)
import Data.List.NonEmpty
import qualified Data.Serialize as SZ
import Data.Text (Text)
import Data.Text.Encoding
import Data.Thyme (UTCTime)

import Kadena.Types.Base
import Kadena.Types.Spec
import Kadena.Types.Command
import Kadena.Types.Comms
import Kadena.Types.Dispatch
import Kadena.Types.Message
import Kadena.Types.Sender
import Kadena.Util.Util

import qualified Pact.Types.API as P
import qualified Pact.Types.Command as Pact
import qualified Pact.Types.Hash as P

data Publish = Publish
  { pConsensus :: MVar PublishedConsensus
  , pDispatch :: Dispatch
  , pNow :: IO UTCTime
  , pNodeId :: NodeId
  }

publish
  :: MonadIO m
  => Publish
  -> (forall a . String -> m a)
  -> [(RequestKey,CMDWire)]
  -> m P.RequestKeys
publish Publish{..} die rpcs = do
  PublishedConsensus{..} <- liftIO (tryReadMVar pConsensus) >>=
    fromMaybeM (die "Invariant error: consensus unavailable")
  ldr <- fromMaybeM
    (die (show pNodeId ++ ": There is no current leader. System unavaiable, please try again later"))
    _pcLeader
  rAt <- ReceivedAt <$> liftIO pNow
  cmds' <- return $! snd <$> rpcs
  let rks' = case nonEmpty (fst <$> rpcs) of
               Nothing -> die (show pNodeId ++ ": List of RequestKeys cannot be empty")
               Just nonEmp -> return $ P.RequestKeys nonEmp
  if pNodeId == ldr
  then  -- dispatch internally if we're leader, otherwise send outbound
    liftIO $ writeComm (_dispInboundCMD pDispatch) $ InboundCMDFromApi $ (rAt, NewCmdInternal cmds')
  else
    liftIO $ writeComm (_dispSenderService pDispatch) $! ForwardCommandToLeader (NewCmdRPC cmds' NewMsg)
  rks'

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
buildCCCmdRpc c@ClusterChangeCommand {..} = (RequestKey (P.toUntypedHash _cccHash), clusterChgTextToCMDWire c)

clusterChgTextToCMDWire :: ClusterChangeCommand Text -> CMDWire
clusterChgTextToCMDWire cmd = clusterChgBSToCMDWire (encodeUtf8 <$> cmd)

clusterChgBSToCMDWire :: ClusterChangeCommand ByteString -> CMDWire
clusterChgBSToCMDWire = CCCWire . SZ.encode
