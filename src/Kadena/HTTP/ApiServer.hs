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
import System.FilePath
import System.Directory
import Data.Thyme.Clock

import qualified Pact.Types.Runtime as Pact
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
import qualified Kadena.Sender.Types as Sender
import qualified Kadena.Commit.Types as Commit
import Kadena.Types.Dispatch
import Kadena.Util.Util

import Kadena.HTTP.Static

data ApiEnv = ApiEnv
  { _aiLog :: String -> IO ()
  , _aiDispatch :: Dispatch
  , _aiConfig :: Config.GlobalConfigMVar
  , _aiPubConsensus :: MVar PublishedConsensus
  , _aiGetTimestamp :: IO UTCTime
  }
makeLenses ''ApiEnv

type Api a = ReaderT ApiEnv Snap a

runApiServer :: Dispatch -> Config.GlobalConfigMVar -> (String -> IO ())
             -> Int -> MVar PublishedConsensus -> IO UTCTime -> IO ()
runApiServer dispatch conf logFn port mPubConsensus' timeCache' = catchAndRethrow "ApiServer" $ do
  logFn $ "[Service|API]: starting on port " ++ show port
  let conf' = ApiEnv logFn dispatch conf mPubConsensus' timeCache'
  rconf <- Config._gcConfig <$> readMVar conf
  let logDir' = _logDir rconf
      hostStaticDir' = _hostStaticDir rconf
  serverConf' <- serverConf port logFn logDir'
  httpServe serverConf' $
    applyCORS defaultOptions $ methods [GET, POST] $
    route $ ("api/v1", runReaderT api conf'):(staticRoutes hostStaticDir')

serverConf :: MonadSnap m => Int -> (String -> IO ()) -> FilePath -> IO (Snap.Config m a)
serverConf port dbgFn logDir' = do
  let errorLog = logDir' </> "error.log"
  let accessLog = logDir' </> "access.log"
  doesFileExist errorLog >>= \x -> when x $ dbgFn ("Creating " ++ errorLog) >> writeFile errorLog ""
  doesFileExist accessLog >>= \x -> when x $ dbgFn ("Creating " ++ accessLog) >> writeFile accessLog ""
  return $ setErrorLog (ConfigFileLog errorLog) $
    setAccessLog (ConfigFileLog accessLog) $
    setPort port defaultConfig

api :: Api ()
api = route [
       ("send",sendPublicBatch)
      ,("poll",poll)
      ,("listen",registerListener)
      ,("local",sendLocal)
      ]

sendLocal :: Api ()
sendLocal = do
  (cmd :: Pact.Command BS.ByteString) <- fmap encodeUtf8 <$> readJSON
  mv <- liftIO newEmptyMVar
  c <- view $ aiDispatch . commitService
  liftIO $ writeComm c (Commit.ExecLocal cmd mv)
  r <- liftIO $ takeMVar mv
  writeResponse $ ApiSuccess $ r

sendPublicBatch :: Api ()
sendPublicBatch = do
  SubmitBatch cmds <- readJSON
  when (null cmds) $ die "Empty Batch"
  PublishedConsensus{..} <- view aiPubConsensus >>= liftIO . tryReadMVar >>= fromMaybeM (die "Invariant error: consensus unavailable")
  conf <- view aiConfig >>= fmap Config._gcConfig . liftIO . readMVar
  ldr <- fromMaybeM (die "System unavaiable, please try again later") _pcLeader
  rAt <- ReceivedAt <$> now
  log $ "received batch of " ++ show (length cmds)
  rpcs <- return $ buildCmdRpc <$> cmds
  cmds' <- return $! snd <$> rpcs
  rks' <- return $ RequestKeys $! fst <$> rpcs
  if _nodeId conf == ldr
  then do -- dispatch internally if we're leader, otherwise send outbound
    oChan <- view (aiDispatch.inboundCMD)
    liftIO $ writeComm oChan $ InboundCMDFromApi $ (rAt, NewCmdInternal cmds')
    writeResponse $ ApiSuccess rks'
  else do
    oChan <- view (aiDispatch.senderService)
    liftIO $ writeComm oChan $! Sender.ForwardCommandToLeader (NewCmdRPC cmds' NewMsg)
    writeResponse $ ApiSuccess rks'

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
scrToAr SmartContractResult{..} =
  let metaData' = Just $ toJSON $ _cmdrLatMetrics
  in ApiResult (toJSON (Pact._crResult _scrResult)) (Pact._crTxId _scrResult) metaData'
scrToAr ConsensusConfigResult{..} =
  let metaData' = Just $ toJSON $ _cmdrLatMetrics
  -- TODO: fix ApiResult to handle more than just TxId
  in ApiResult (toJSON _ccrResult) (Just $ Pact.TxId $ fromIntegral _cmdrLogIndex) metaData'

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
now = view aiGetTimestamp >>= liftIO
