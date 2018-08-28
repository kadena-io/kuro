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
import Control.Lens
import Control.Concurrent
import Control.Exception.Lifted (SomeException, throw, try)
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
import qualified Data.Set as Set
import qualified Data.Serialize as SZ

import Snap.Core
import Snap.Http.Server as Snap
import Snap.Util.CORS
import System.FilePath
import System.Directory
import Data.Thyme.Clock

import qualified Pact.Types.Runtime as Pact
import qualified Pact.Types.Command as Pact
import Pact.Types.RPC (PactRPC)
import Pact.Types.API

import Kadena.Command (SubmitCC(..))
import Kadena.Types.Command
import Kadena.Types.Base
import Kadena.Types.Comms
import Kadena.Types.Config as Config
import Kadena.Config.TMVar as Config
import Kadena.Types.Spec
import Kadena.Types.Entity
import Kadena.Types.History (History(..), PossiblyIncompleteResults(..))
import qualified Kadena.Types.History as History
import qualified Kadena.Types.Execution as Exec
import Kadena.Types.Dispatch
import Kadena.Private.Service (encrypt)
import Kadena.Types.Private (PrivatePlaintext(..),PrivateCiphertext(..),Labeled(..),PrivateResult(..))
import Kadena.Consensus.Publish

import Kadena.HTTP.Static

data ApiEnv = ApiEnv
  { _aiLog :: String -> IO ()
  , _aiDispatch :: Dispatch
  , _aiConfig :: GlobalConfigTMVar
  , _aiPublish :: Publish
  }

makeLenses ''ApiEnv

type Api a = ReaderT ApiEnv Snap a

runApiServer :: Dispatch -> Config.GlobalConfigTMVar -> (String -> IO ())
             -> Int -> MVar PublishedConsensus -> IO UTCTime -> IO ()
runApiServer dispatch gcm logFn port mPubConsensus' timeCache' = do
  logFn $ "[Service|API]: starting on port " ++ show port
  rconf <- readCurrentConfig gcm
  let conf' = ApiEnv logFn dispatch gcm $
        Publish
        mPubConsensus'
        dispatch
        timeCache'
        (_nodeId rconf)
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
      ,("private",sendPrivateBatch)
      ,("config", sendClusterChange)
      ]

sendLocal :: Api ()
sendLocal = do
  (cmd :: Pact.Command BS.ByteString) <- fmap encodeUtf8 <$> readJSON
  mv <- liftIO newEmptyMVar
  c <- view $ aiDispatch . dispExecService
  liftIO $ writeComm c (Exec.ExecLocal cmd mv)
  r <- liftIO $ takeMVar mv
  writeResponse $ ApiSuccess $ r

sendPublicBatch :: Api ()
sendPublicBatch = do
  SubmitBatch cmds <- readJSON
  when (null cmds) $ die "Empty Batch"
  log $ "public: received batch of " ++ show (length cmds)
  rpcs <- return $ buildCmdRpc <$> cmds
  queueRpcs rpcs

sendClusterChange :: Api ()
sendClusterChange = do
  SubmitCC ccCmds <- readJSON
  when (null ccCmds) $ die "Empty cluster change batch"
  when (length ccCmds /= 2) $ die "Exactly two cluster change commands required -- one Transitional, one Final"
  let transCmd = head ccCmds
  let finalCmd = head $ tail $ ccCmds
  let transRpc = buildCCCmdRpc transCmd
  queueRpcsNoResp [transRpc]
  let transListenerReq = ListenerRequest (fst transRpc) --listen for the result of the transitional command
  ccTransResult <- listenFor transListenerReq
  case ccTransResult of
    ClusterChangeSuccess -> do
      log "Transitional CC was sucessful, now ok to send the Final"
      let finalRpc = buildCCCmdRpc finalCmd
      queueRpcs [finalRpc]
      let finalListenerReq = ListenerRequest (fst finalRpc)
      ccFinalResult <- listenFor finalListenerReq
      case ccFinalResult of
        ClusterChangeSuccess -> log "Final CC was sucessful, Config change complete"
        ClusterChangeFailure eFinal -> log $ "Final cluster change failed: " ++ eFinal
    ClusterChangeFailure eTrans  -> log $ "Transitional cluster change failed: " ++ eTrans

queueRpcs :: [(RequestKey,CMDWire)] -> Api ()
queueRpcs rpcs = do
  p <- view aiPublish
  rks <- publish p die rpcs
  writeResponse $ ApiSuccess rks

queueRpcsNoResp :: [(RequestKey,CMDWire)] -> Api ()
queueRpcsNoResp rpcs = do
    p <- view aiPublish
    _rks <- publish p die rpcs
    return ()

sendPrivateBatch :: Api ()
sendPrivateBatch = do
  conf <- view aiConfig >>= liftIO . readCurrentConfig
  unless (_ecSending $ _entity conf) $ die "Node is not configured as private sending node"
  SubmitBatch cmds <- readJSON
  log $ "private: received batch of " ++ show (length cmds)
  when (null cmds) $ die "Empty Batch"
  rpcs <- forM cmds $ \c -> do
    let cb@Pact.Command{..} = fmap encodeUtf8 c
    case eitherDecodeStrict' _cmdPayload of
      Left e -> die $ "JSON payload decode failed: " ++ show e
      Right (Pact.Payload{..} :: Pact.Payload (PactRPC T.Text)) -> case _pAddress of
        Nothing -> die $ "sendPrivateBatch: missing address in payload: " ++ show c
        Just Pact.Address{..} -> do
          pchan <- view (aiDispatch.dispPrivateChannel)
          if _aFrom `Set.member` _aTo || _aFrom /= (_elName $ _ecLocal$ _entity conf)
            then die $ "sendPrivateBatch: invalid address in payload: " ++ show c
            else do
              er <- liftIO $ encrypt pchan $
                PrivatePlaintext _aFrom (_alias (_nodeId conf)) _aTo (SZ.encode cb)
              case er of
                Left e -> die $ "sendPrivateBatch: encrypt failed: " ++ show e ++ ", command: " ++ show c
                Right pc@PrivateCiphertext{..} -> do
                  let hsh = hash $ _lPayload $ _pcEntity
                      hc = Hashed pc hsh
                  return (RequestKey hsh,PCWire $ SZ.encode hc)
  queueRpcs rpcs

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
scrToAr cr = case cr of
  SmartContractResult{..} ->
    ApiResult (toJSON (Pact._crResult _scrResult)) (Pact._crTxId _scrResult) metaData'
  ConsensusChangeResult{..} ->
    ApiResult (toJSON _concrResult) tidFromLid metaData'
  PrivateCommandResult{..} ->
    ApiResult (handlePR _pcrResult) tidFromLid metaData'
  where metaData' = Just $ toJSON $ _crLatMetrics $ cr
        tidFromLid = Just $ Pact.TxId $ fromIntegral $ _crLogIndex $ cr
        handlePR (PrivateFailure e) = toJSON $ "ERROR: " ++ show e
        handlePR PrivatePrivate = String "Private message"
        handlePR (PrivateSuccess pr) = toJSON (Pact._crResult pr)

checkHistoryForResult :: HashSet RequestKey -> Api PossiblyIncompleteResults
checkHistoryForResult rks = do
  hChan <- view (aiDispatch.dispHistoryChannel)
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
  writeLBS $ encode $ (ApiFailure ("Kadena.HTTP.ApiServer" ++ res) :: ApiResponse ())
  finishWith =<< getResponse

readJSON :: (Show t, FromJSON t) => Api t
readJSON = do
  b <- readRequestBody 1000000000
  snd <$> tryParseJSON b

tryParseJSON
  :: (Show t, FromJSON t) =>
     BSL.ByteString -> Api (BS.ByteString, t)
tryParseJSON b = case eitherDecode b of
    Right v -> return (toStrict b,v)
    Left e -> die e

setJSON :: Api ()
setJSON = modifyResponse $ setHeader "Content-Type" "application/json"

writeResponse :: ToJSON j => j -> Api ()
writeResponse j = setJSON >> writeLBS (encode j)

listenFor :: ListenerRequest -> Api ClusterChangeResult
listenFor (ListenerRequest rk) = do
  hChan <- view (aiDispatch.dispHistoryChannel)
  m <- liftIO $ newEmptyMVar
  liftIO $ writeComm hChan $ RegisterListener (HashMap.fromList [(rk,m)])
  log $ "listenFor -- registered Listener for: " ++ show rk
  res <- liftIO $ readMVar m
  case res of
    History.GCed msg -> do
      let errStr = "Listener GCed for: " ++ show rk ++ " because " ++ msg
      return $ ClusterChangeFailure errStr
    History.ListenerResult cr -> do
      log $ "listenFor -- Listener Serviced for: " ++ show rk
      return $ _concrResult cr

listenerTimeout :: Int
listenerTimeout = 300 

registerListener :: Api ()
registerListener = do
  extendTimeout listenerTimeout
  (theEither :: Either SomeException ()) <- try $ do 
    (ListenerRequest rk) <- readJSON
    hChan <- view (aiDispatch.dispHistoryChannel)
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
  case theEither of
    Left e -> do
      liftIO $ putStrLn $ "Exception in registerListener: " ++ show e 
      throw e
    Right y -> return y
