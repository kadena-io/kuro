{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}

module Kadena.Runtime.Api.ApiServer
    where
import Control.Concurrent
import Control.Monad.Reader
import Data.Aeson hiding (defaultOptions)
import qualified Data.ByteString.Char8 as BS
import Data.ByteString.Lazy (toStrict)
import Control.Lens hiding ((.=))
import Data.Monoid
import Prelude hiding (log)
import qualified Data.Serialize as SZ
import Data.Thyme.Clock
import Data.Thyme.Time.Core (unUTCTime, toMicroseconds)
import Snap.Http.Server as Snap
import Snap.Core
import qualified Data.Map.Strict as M
import Snap.CORS

import Kadena.Types.Command
import Kadena.Types.Base
import Kadena.Types.Comms
import Kadena.Types.Message
import Kadena.Types.Config as Config
import Kadena.Types.Spec
import Kadena.Command.Types
import Kadena.Types.Dispatch
import Kadena.Util.Util
import Kadena.Types.Api


data ApiEnv = ApiEnv {
      _aiApplied :: MVar (M.Map RequestId AppliedCommand)
    , _aiLog :: String -> IO ()
    , _aiDispatch :: Dispatch
    , _aiConfig :: Config.Config
    , _aiPubConsensus :: MVar PublishedConsensus
}
makeLenses ''ApiEnv


type Api a = ReaderT ApiEnv Snap a


runApiServer :: Dispatch -> Config.Config -> (String -> IO ()) ->
                MVar (M.Map RequestId AppliedCommand) -> Int -> MVar PublishedConsensus -> IO ()
runApiServer dispatch conf logFn appliedMap port mPubConsensus' = do
  putStrLn $ "runApiServer: starting on port " ++ show port
  httpServe (serverConf port) $
    applyCORS defaultOptions $ methods [GET, POST] $
    route [ ("api", runReaderT api (ApiEnv appliedMap logFn dispatch conf mPubConsensus'))]

api :: Api ()
api = route [
       ("public/send",sendPublic)
      ,("public/batch",sendPublicBatch)
      ,("poll",poll)
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
  let r = eitherDecode b
  case r of
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

mkRequestId :: Alias -> String -> RequestId
mkRequestId a s = RequestId $ show a ++ ":" ++ s

sendPublic :: Api ()
sendPublic = do
  (_,pm) <- readJSON
  (rid,rpc) <- buildCmdRpc pm
  enqueueRPC rpc
  writeResponse $ SubmitSuccess [rid]

buildCmdRpc :: PactMessage -> Api (RequestId,SignedRPC)
buildCmdRpc PactMessage {..} = do
  storedCK <- M.lookup _pmAlias <$> view (aiConfig.clientPublicKeys)
  unless (storedCK == Just _pmKey) $ die 400 "Invalid alias/public key"
  let rid = mkRequestId _pmAlias _pmRequestId
  let ce = CommandEntry $! SZ.encode $! PublicMessage $! _pmPayload
  return $! (rid,mkCmdRpc ce _pmAlias rid (Digest _pmAlias _pmSig _pmKey CMD))

sendPublicBatch :: Api ()
sendPublicBatch = do
  (_,!cs) <- fmap cmds <$> readJSON
  when (null cs) $ die 400 "Empty batch"
  rpcs <- mapM buildCmdRpc cs
  let PactMessage {..} = head cs
      dig = Digest _pmAlias (Sig "") _pmKey CMDB
      rpc = mkCmdBatchRPC (map snd rpcs) dig
  enqueueRPC $! rpc -- CMDB' $! CommandBatch (reverse cmds) NewMsg
  writeResponse $ SubmitSuccess (map fst rpcs)


poll :: Api ()
poll = do
  (_,rids) <- fmap requestIds <$> readJSON
  m <- view aiApplied >>= liftIO . tryReadMVar >>= fromMaybeM (die 500 "Results unavailable")
  setJSON
  writeBS "{ \"status\": \"Success\", \"responses\": ["
  forM_ (zip rids [(0 :: Int)..]) $ \(rid@RequestId {..},i) -> do
         when (i>0) $ writeBS ", "
         writeBS "{ \"requestId\": "
         writeBS (BS.pack (show _unRequestId))
         writeBS ", \"response\": "
         case M.lookup rid m of
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

mkPublicCommand :: BS.ByteString -> Api (Command,RequestId)
mkPublicCommand bs = do
  rid <- undefined -- view aiNextRequestId >>= \f -> liftIO f
  nid <- view (aiConfig.nodeId)
  return $! (Command (CommandEntry $! SZ.encode $! PublicMessage $! bs) (_alias nid) rid Valid NewMsg,rid)


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
