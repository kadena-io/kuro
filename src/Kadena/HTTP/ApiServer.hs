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

import Data.Monoid

import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BSL
import Data.ByteString.Lazy (toStrict)
import Data.Aeson hiding (defaultOptions)
import qualified Data.Serialize as SZ

import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map

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
                            , PossiblyIncompleteResults(..)
                            , ListenerResult(..))
import Kadena.Types.Dispatch
import Kadena.Util.Util

import Kadena.Types.Api

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
       ("public/send",sendPublic)
      ,("public/batch",sendPublicBatch)
      ,("poll",poll)
      ,("listen",registerListener)
      ]

log :: String -> Api ()
log s = view aiLog >>= \f -> liftIO (f s)

die :: Int -> BS.ByteString -> Api t
die code msg = do
  let s = "Error " <> BS.pack (show code) <> ": " <> msg
  writeBS s
  log (BS.unpack s)
  withResponse (finishWith . setResponseStatus code "Error")

readJSON :: FromJSON t => Api (BS.ByteString,t)
readJSON = do
  b <- readRequestBody 1000000000
  tryParseJSON b

tryParseJSON
  :: FromJSON t =>
     BSL.ByteString -> Api (BS.ByteString, t)
tryParseJSON b = case eitherDecode b of
    Right v -> return (toStrict b,v)
    Left e -> die 400 (BS.pack e)

setJSON :: Api ()
setJSON = modifyResponse $ setHeader "Content-Type" "application/json"

writeResponse :: ToJSON j => j -> Api ()
writeResponse j = setJSON >> writeLBS (encode j)

{-
aliases need to be verified by api against public key
then, alias can be paired with requestId in message to create unique rid
polling can then be on alias and client rid
-}

sendPublic :: Api ()
sendPublic = do
  (_,pm) <- readJSON
  (rk,rpc) <- buildCmdRpc pm
  enqueueRPC rpc
  writeResponse $ SubmitSuccess [rk]

buildCmdRpc :: PactMessage -> Api (RequestKey,SignedRPC)
buildCmdRpc PactMessage {..} = do
  (_,PactEnvelope {..} :: PactEnvelope PactRPC) <- tryParseJSON (BSL.fromStrict $ _pmEnvelope)
  storedCK <- Map.lookup _peAlias <$> view (aiConfig.clientPublicKeys)
  unless (storedCK == Just _pmKey) $ die 400 "Invalid alias/public key"
  rid <- getNextRequestId
  let ce = CommandEntry $! SZ.encode $! PublicMessage $! _pmEnvelope
      hsh = hash $ SZ.encode $ CMDWire (ce,_peAlias,rid)
  return (RequestKey hsh,mkCmdRpc ce _peAlias rid (Digest _peAlias _pmSig _pmKey CMD hsh))

sendPublicBatch :: Api ()
sendPublicBatch = do
  (_,!cs) <- fmap cmds <$> readJSON
  when (null cs) $ die 400 "Empty batch"
  rpcs <- mapM buildCmdRpc cs
  let PactMessage {..} = head cs
      btch = map snd rpcs
      hsh = hash $ SZ.encode $ btch
      dig = Digest "batch" (Sig "") _pmKey CMDB hsh
      rpc = mkCmdBatchRPC (map snd rpcs) dig
  enqueueRPC $! rpc -- CMDB' $! CommandBatch (reverse cmds) NewMsg
  writeResponse $ SubmitSuccess (map fst rpcs)

poll :: Api ()
poll = do
  (_,rks) <- readJSON
  PossiblyIncompleteResults{..} <- checkHistoryForResult (Set.fromList rks)
  setJSON
  writeBS "{ \"status\": \"Success\", \"responses\": ["
  forM_ (zip rks [(0 :: Int)..]) $ \(rk,i) -> do
         when (i>0) $ writeBS ", "
         writeBS "{ \"requestKey\": "
         writeBS $ SZ.encode rk
         writeBS ", \"response\": "
         case Map.lookup rk possiblyIncompleteResults of
           Nothing -> writeBS "{ \"status\": \"Not Found\" }"
           Just (AppliedCommand (CommandResult cr) lat _) -> do
                               writeBS cr
                               writeBS ", \"latency\": "
                               writeBS (BS.pack (show lat))
         writeBS "}"
  writeBS "] }"

serverConf :: MonadSnap m => Int -> Snap.Config m a
serverConf port = setErrorLog (ConfigFileLog "log/error.log") $
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
  env <- ask
  let conf = _aiConfig env
  PublishedConsensus {..} <- fromMaybeM (die 500 "Invariant error: consensus unavailable") =<<
                              liftIO (tryReadMVar (_aiPubConsensus env))
  ldr <- fromMaybeM (die 500 "System unavaiable, please try again later") _pcLeader
  if _nodeId conf == ldr
  then do -- dispatch internally if we're leader, otherwise send outbound
    ts <- liftIO getCurrentTime
    liftIO $ writeComm (_inboundCMD $ _aiDispatch env) $! InboundCMD (ReceivedAt ts, signedRPC)
  else liftIO $ writeComm (_outboundGeneral $ _aiDispatch env) $!
       directMsg [(ldr,SZ.encode signedRPC)]

checkHistoryForResult :: Set RequestKey -> Api PossiblyIncompleteResults
checkHistoryForResult rks = do
  hChan <- view (aiDispatch.historyChannel)
  m <- liftIO $ newEmptyMVar
  liftIO $ writeComm hChan $ QueryForResults (rks,m)
  liftIO $ readMVar m

registerListener :: Api ()
registerListener = do
  (_,rk) <- readJSON
  hChan <- view (aiDispatch.historyChannel)
  m <- liftIO $ newEmptyMVar
  liftIO $ writeComm hChan $ RegisterListener (Map.fromList [(rk,m)])
  res <- liftIO $ readMVar m
  case res of
    GCed -> die 500 "Listener was GCed before fulfilled, likely the command doesn't exist"
    ListenerResult res' -> do
      setJSON
      writeBS "{ \"status\": \"Success\", \"responses\": ["
      writeBS "{ \"requestKey\": "
      writeBS $ SZ.encode rk
      writeBS ", \"response\": "
      AppliedCommand (CommandResult cr) lat _ <- return res'
      writeBS cr
      writeBS ", \"latency\": "
      writeBS (BS.pack (show lat))
      writeBS "}"
      writeBS "] }"
