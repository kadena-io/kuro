{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}

-- TODO: add latency back into the apiResult

module Kadena.HTTP.ApiServer
  ( runApiServer
  ) where

import Prelude hiding (log)
import Control.Lens hiding ((.=))
import Control.Concurrent
import Data.IORef
import Control.Monad.Reader

import Data.Aeson hiding (defaultOptions, Result(..))
import Data.ByteString.Lazy (toStrict)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text as T
import Data.Text.Encoding

import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap

import qualified Data.Serialize as SZ

import Snap.Core
import Snap.Http.Server as Snap
import Snap.CORS
import Data.Thyme.Clock

import qualified Pact.Types.Command as Pact
import Pact.Types.API

import Kadena.Types.Command
import Kadena.Types.Base
import Kadena.Types.Comms
import Kadena.Types.Message
import Kadena.Types.Config as Config
import Kadena.Types.Spec
import Kadena.History.Types ( History(..)
                            , PossiblyIncompleteResults(..))
import qualified Kadena.History.Types as History
import Kadena.Types.Dispatch
import Kadena.Util.Util

import Kadena.HTTP.Static

data ApiEnv = ApiEnv
  { _aiLog :: String -> IO ()
  , _aiDispatch :: Dispatch
  , _aiConfig :: IORef Config.Config
  , _aiPubConsensus :: MVar PublishedConsensus
  , _aiGetTimestamp :: IO UTCTime
  }
makeLenses ''ApiEnv

type Api a = ReaderT ApiEnv Snap a

runApiServer :: Dispatch -> IORef Config.Config -> (String -> IO ())
             -> Int -> MVar PublishedConsensus -> IO UTCTime -> IO ()
runApiServer dispatch conf logFn port mPubConsensus' timeCache' = do
  putStrLn $ "[Service|API]: starting on port " ++ show port
  let conf' = ApiEnv logFn dispatch conf mPubConsensus' timeCache'
  httpServe (serverConf port) $
    applyCORS defaultOptions $ methods [GET, POST] $
    route $ ("api/v1", runReaderT api conf'):staticRoutes

api :: Api ()
api = route [
       ("send",sendPublicBatch)
      ,("poll",poll)
      ,("listen",registerListener)
      ,("local",sendLocal)
      ]

sendLocal :: Api ()
sendLocal = undefined

sendPublicBatch :: Api ()
sendPublicBatch = do
  SubmitBatch cmds <- readJSON
  when (null cmds) $ die "Empty Batch"
  PublishedConsensus{..} <- view aiPubConsensus >>= liftIO . tryReadMVar >>= fromMaybeM (die "Invariant error: consensus unavailable")
  conf <- view aiConfig >>= liftIO . readIORef
  ldr <- fromMaybeM (die "System unavaiable, please try again later") _pcLeader
  rAt <- ReceivedAt <$> now
  if _nodeId conf == ldr
  then do -- dispatch internally if we're leader, otherwise send outbound
    rpcs <- return $ group 8000 $ buildCmdRpc <$> cmds
    oChan <- view (aiDispatch.inboundCMD)
    mapM_ (\rpcs' -> liftIO $ writeComm oChan $ InboundCMDFromApi $ (rAt, NewCmdInternal $ snd <$> rpcs')) rpcs
    writeResponse $ ApiSuccess $ RequestKeys $ concat $ fmap fst <$> rpcs
  else do
    oChan <- view (aiDispatch.outboundGeneral)
    let me = Config._nodeId conf
        sk = Config._myPrivateKey conf
        pk = Config._myPublicKey conf
    cmds' <- return $ pactTextToCMDWire <$> cmds
    liftIO $ writeComm oChan $! directMsg [(ldr,SZ.encode $ toWire me pk sk $ NewCmdRPC cmds' NewMsg)]

pactTextToCMDWire :: Pact.Command T.Text -> CMDWire
pactTextToCMDWire cmd = SCCWire $ SZ.encode (encodeUtf8 <$> cmd)

buildCmdRpc :: Pact.Command T.Text -> (RequestKey,CMDWire)
buildCmdRpc c@Pact.PublicCommand{..} = (RequestKey _cmdHash, pactTextToCMDWire c)

poll :: Api ()
poll = do
  (Poll rks) <- readJSON
  log $ "Polling for " ++ show rks
  PossiblyIncompleteResults{..} <- checkHistoryForResult (HashSet.fromList rks)
  when (HashMap.null possiblyIncompleteResults) $ log $ "No results found for poll!" ++ show rks
  writeResponse $ pollResultToReponse possiblyIncompleteResults

pollResultToReponse :: HashMap RequestKey CommandResult -> ApiResponse PollResponses
pollResultToReponse m = ApiSuccess $ PollResponses $ scrToAr <$> m

scrToAr :: CommandResult -> ApiResult
scrToAr SmartContractResult{..} = ApiResult (toJSON (Pact._crResult _scrResult)) (Pact._crTxId _scrResult) metaData'
  where
    metaData' = Just $ toJSON $ LatencyMetrics { _lmFullLatency = _cmdrLatency}

serverConf :: MonadSnap m => Int -> Snap.Config m a
serverConf port =
  setErrorLog (ConfigFileLog "log/error.log") $
  setAccessLog (ConfigFileLog "log/access.log") $
  setPort port defaultConfig

checkHistoryForResult :: HashSet RequestKey -> Api PossiblyIncompleteResults
checkHistoryForResult rks = do
  hChan <- view (aiDispatch.historyChannel)
  m <- liftIO $ newEmptyMVar
  liftIO $ writeComm hChan $ QueryForResults (rks,m)
  liftIO $ readMVar m

log :: String -> Api ()
log s = view aiLog >>= \f -> liftIO (f $ "[Service|Api]: " ++ s)

die :: String -> Api t
die res = do
  _ <- getResponse -- chuck what we've done so far
  setJSON
  log res
  writeLBS $ encode $ (ApiFailure res :: ApiResponse ())
  finishWith =<< getResponse

readJSON :: FromJSON t => Api t
readJSON = do
  b <- readRequestBody 1000000000
  snd <$> tryParseJSON b

tryParseJSON
  :: FromJSON t =>
     BSL.ByteString -> Api (BS.ByteString, t)
tryParseJSON b = case eitherDecode b of
    Right v -> return (toStrict b,v)
    Left e -> die e

setJSON :: Api ()
setJSON = modifyResponse $ setHeader "Content-Type" "application/json"

writeResponse :: ToJSON j => j -> Api ()
writeResponse j = setJSON >> writeLBS (encode j)

group :: Int -> [a] -> [[a]]
group _ [] = []
group n l
  | n > 0 = take n l : (group n (drop n l))
  | otherwise = error "Negative n"

registerListener :: Api ()
registerListener = do
  (ListenerRequest rk) <- readJSON
  hChan <- view (aiDispatch.historyChannel)
  m <- liftIO $ newEmptyMVar
  liftIO $ writeComm hChan $ RegisterListener (HashMap.fromList [(rk,m)])
  log $ "Registered Listener for: " ++ show rk
  res <- liftIO $ readMVar m
  case res of
    History.GCed msg -> do
      log $ "Listener GCed for: " ++ show rk ++ " because " ++ msg
      die msg
    History.ListenerResult scr -> do
      log $ "Listener Serviced for: " ++ show rk
      setJSON
      ls <- return $ ApiSuccess $ scrToAr scr
      writeLBS $ encode ls

now :: Api UTCTime
now = view (aiGetTimestamp) >>= liftIO
