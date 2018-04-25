{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
module Kadena.Consensus.Publish
  (Publish(..),publish,pactTextToCMDWire,buildCmdRpc,buildCmdRpcBS,pactBSToCMDWire)
  where

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
import Kadena.Sender.Types
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
  ldr <- fromMaybeM (die "System unavaiable, please try again later") _pcLeader
  rAt <- ReceivedAt <$> liftIO pNow
  cmds' <- return $! snd <$> rpcs
  rks' <- return $ RequestKeys $! fst <$> rpcs
  if pNodeId == ldr
  then  -- dispatch internally if we're leader, otherwise send outbound
    liftIO $ writeComm (_inboundCMD pDispatch) $ InboundCMDFromApi $ (rAt, NewCmdInternal cmds')
  else
    liftIO $ writeComm (_senderService pDispatch) $! ForwardCommandToLeader (NewCmdRPC cmds' NewMsg)
  return rks'

pactBSToCMDWire :: Pact.Command ByteString -> CMDWire
pactBSToCMDWire = SCCWire . SZ.encode

pactTextToCMDWire :: Pact.Command Text -> CMDWire
pactTextToCMDWire cmd = pactBSToCMDWire (encodeUtf8 <$> cmd)

buildCmdRpc :: Pact.Command Text -> (RequestKey,CMDWire)
buildCmdRpc c@Pact.Command{..} = (RequestKey _cmdHash, pactTextToCMDWire c)

buildCmdRpcBS :: Pact.Command ByteString -> (RequestKey,CMDWire)
buildCmdRpcBS c@Pact.Command{..} = (RequestKey _cmdHash, pactBSToCMDWire c)
