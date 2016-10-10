{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}

module Kadena.HTTP.ApiServer
  ( runApiServer
  ) where

import Prelude hiding (log)
import Control.Lens hiding ((.=))
import Control.Concurrent
import Control.Monad.Reader

import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BSL
import Data.ByteString.Lazy (toStrict)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Data.Aeson hiding (defaultOptions, Result(..))
import qualified Data.Serialize as SZ

import Data.Thyme.Clock
import Data.Thyme.Time.Core (unUTCTime, toMicroseconds)

import Snap.Core
import Snap.Http.Server as Snap
import Snap.CORS

import Kadena.Types.Command
import Kadena.Types.Base
import Kadena.Types.Comms
import Kadena.Types.Message
import Kadena.Types.Config as Config
import Kadena.Types.Spec
import Kadena.Command.Types
import Kadena.History.Types ( History(..)
                            , PossiblyIncompleteResults(..))
import qualified Kadena.History.Types as History
import Kadena.Types.Dispatch
import Kadena.Util.Util

import Kadena.HTTP.Types

data ApiEnv = ApiEnv
  { _aiLog :: String -> IO ()
  , _aiIdCounter :: MVar Int
  , _aiDispatch :: Dispatch
  , _aiConfig :: Config.Config
  , _aiPubConsensus :: MVar PublishedConsensus
  }
makeLenses ''ApiEnv

type Api a = ReaderT ApiEnv Snap a

initRequestId :: IO Int
initRequestId = do
  UTCTime _ time <- unUTCTime <$> getCurrentTime
  return $ fromIntegral $ toMicroseconds time

runApiServer :: Dispatch -> Config.Config -> (String -> IO ())
             -> Int -> MVar PublishedConsensus -> IO ()
runApiServer dispatch conf logFn port mPubConsensus' = do
  putStrLn $ "runApiServer: starting on port " ++ show port
  m <- newMVar =<< initRequestId
  httpServe (serverConf port) $
    applyCORS defaultOptions $ methods [GET, POST] $
    route [ ("api", runReaderT api (ApiEnv logFn m dispatch conf mPubConsensus'))]

api :: Api ()
api = route [
       ("public/send",sendPublicBatch)
      ,("poll",poll)
      ,("listen",registerListener)
      ]

log :: String -> Api ()
log s = view aiLog >>= \f -> liftIO (f s)

die :: (Show a, ToJSON a) => a -> Api t
die res = do
  _ <- getResponse -- chuck what we've done so far
  setJSON
  log (show res)
  writeLBS $ encode res
  finishWith =<< getResponse

readJSON :: FromJSON t => Api (BS.ByteString,t)
readJSON = do
  b <- readRequestBody 1000000000
  tryParseJSON b

tryParseJSON
  :: FromJSON t =>
     BSL.ByteString -> Api (BS.ByteString, t)
tryParseJSON b = case eitherDecode b of
    Right v -> return (toStrict b,v)
    Left e -> die $ ApiResponse Failure e

setJSON :: Api ()
setJSON = modifyResponse $ setHeader "Content-Type" "application/json"

writeResponse :: ToJSON j => j -> Api ()
writeResponse j = setJSON >> writeLBS (encode j)

{-
aliases need to be verified by api against public key
then, alias can be paired with requestId in message to create unique rid
polling can then be on alias and client rid
-}

buildCmdRpc :: PactMessage -> Api (RequestKey,SignedRPC)
buildCmdRpc PactMessage {..} = do
  (_,PactEnvelope {..} :: PactEnvelope PactRPC) <- tryParseJSON (BSL.fromStrict $ _pmEnvelope)
  storedCK <- Map.lookup _peAlias <$> view (aiConfig.clientPublicKeys)
  unless (storedCK == Just _pmKey) $ die $ ApiResponse Failure ("Invalid alias/public key" :: String)
  rid <- getNextRequestId
  let ce = CommandEntry $! SZ.encode $! PublicMessage $! _pmEnvelope
      hsh = hash $ SZ.encode $ CMDWire (ce,_peAlias,rid)
  return (RequestKey hsh,mkCmdRpc ce _peAlias rid (Digest _peAlias _pmSig _pmKey CMD hsh))

sendPublicBatch :: Api ()
sendPublicBatch = do
  (_,SubmitBatch cmds) <- readJSON
  when (null cmds) $ die $ SubmitBatchFailure $ ApiResponse Failure "Empty Batch"
  rpcs <- mapM buildCmdRpc cmds
  let PactMessage {..} = head cmds
      btch = map snd rpcs
      hsh = hash $ SZ.encode $ btch
      dig = Digest "batch" (Sig "") _pmKey CMDB hsh
      rpc = mkCmdBatchRPC (map snd rpcs) dig
  enqueueRPC $! rpc -- CMDB' $! CommandBatch (reverse cmds) NewMsg
  writeResponse $ SubmitBatchSuccess $ ApiResponse Success $ RequestKeys (map fst rpcs)

poll :: Api ()
poll = do
  (_,Poll rks) <- readJSON
  PossiblyIncompleteResults{..} <- checkHistoryForResult (Set.fromList rks)
  setJSON
  writeLBS $ encode $ pollResultToReponse possiblyIncompleteResults

pollResultToReponse :: Map RequestKey AppliedCommand -> PollResponse
pollResultToReponse m = PollSuccess $ ApiResponse Success (kvToRes <$> Map.toList m)
  where
    kvToRes (rk,AppliedCommand{..}) = PollResult { _prRequestKey = rk, _prLatency = _acLatency, _prResponse = _acResult}

serverConf :: MonadSnap m => Int -> Snap.Config m a
serverConf port =
  setErrorLog (ConfigFileLog "log/error.log") $
  setAccessLog (ConfigFileLog "log/access.log") $
  setPort port defaultConfig

getNextRequestId :: Api RequestId
getNextRequestId = do
  cntr <- view aiIdCounter
  cnt <- liftIO (takeMVar cntr)
  liftIO $ putMVar cntr (cnt + 1)
  return $ RequestId $ show cnt

_mkPublicCommand :: BS.ByteString -> Api (Command, RequestKey)
_mkPublicCommand bs = do
  rid <- getNextRequestId
  nid <- view (aiConfig.nodeId)
  cmd@Command{..} <- return $! Command (CommandEntry $! SZ.encode $! PublicMessage $! bs) (_alias nid) (RequestId $ show rid) Valid NewMsg
  return (cmd, RequestKey $ hash $ SZ.encode $ CMDWire (_cmdEntry, _cmdClientId, _cmdRequestId))

enqueueRPC :: SignedRPC -> Api ()
enqueueRPC signedRPC = do
  PublishedConsensus{..} <- view aiPubConsensus >>= liftIO . tryReadMVar >>= fromMaybeM (die $ ApiResponse Failure ("Invariant error: consensus unavailable" :: String))
  conf <- view aiConfig
  ldr <- fromMaybeM (die $ ApiResponse Failure ("System unavaiable, please try again later" :: String)) _pcLeader
  if _nodeId conf == ldr
  then do -- dispatch internally if we're leader, otherwise send outbound
    ts <- liftIO getCurrentTime
    oChan <- view (aiDispatch.inboundCMD)
    liftIO $ writeComm oChan $! InboundCMD (ReceivedAt ts, signedRPC)
  else do
    oChan <- view (aiDispatch.outboundGeneral)
    liftIO $ writeComm oChan $! directMsg [(ldr,SZ.encode signedRPC)]

checkHistoryForResult :: Set RequestKey -> Api PossiblyIncompleteResults
checkHistoryForResult rks = do
  hChan <- view (aiDispatch.historyChannel)
  m <- liftIO $ newEmptyMVar
  liftIO $ writeComm hChan $ QueryForResults (rks,m)
  liftIO $ readMVar m

registerListener :: Api ()
registerListener = do
  (_,ListenerRequest rk) <- readJSON
  hChan <- view (aiDispatch.historyChannel)
  m <- liftIO $ newEmptyMVar
  liftIO $ writeComm hChan $ RegisterListener (Map.fromList [(rk,m)])
  res <- liftIO $ readMVar m
  case res of
    History.GCed -> die $ ListenerFailure $ ApiResponse Failure "Listener was GCed before fulfilled, likely the command doesn't exist"
    History.ListenerResult AppliedCommand{..} -> do
      setJSON
      ls <- return $ ListenerSuccess $ ApiResponse Success $ PollResult { _prRequestKey = rk, _prLatency = _acLatency, _prResponse = _acResult}
      writeLBS $ encode ls
