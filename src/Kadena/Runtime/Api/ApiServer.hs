{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Runtime.Api.ApiServer
    where
import Control.Concurrent
import Control.Concurrent.Chan.Unagi
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
import Data.Text (pack)
import GHC.Generics

import Kadena.Types.Command
import Kadena.Types.Base
import Kadena.Types.Comms
import Kadena.Types.Message
import Kadena.Types.Event
import Kadena.Types.Config as Config
import Kadena.Types.Spec
import Kadena.Command.Types
import Kadena.Types.Dispatch
import Kadena.Util.Util


data ApiEnv = ApiEnv {
      _aiApplied :: MVar (M.Map RequestId AppliedCommand)
    , _aiLog :: String -> IO ()
    , _aiDispatch :: Dispatch
    , _aiConfig :: Config.Config
    , _aiPubConsensus :: MVar PublishedConsensus
    , _aiNextRequestId :: IO RequestId
}

data PollRequest = PollRequest {
      requestId :: RequestId
    } deriving (Eq,Show,Generic)
makeLenses ''ApiEnv
instance FromJSON PollRequest

type Api a = ReaderT ApiEnv Snap a


mkNextRequestId :: IO (IO RequestId)
mkNextRequestId = do
  UTCTime _ time <- unUTCTime <$> getCurrentTime
  mv <- newMVar (RequestId $ toMicroseconds time)
  return $ modifyMVar mv (\t -> let t'=succ t in return (t',t'))

runApiServer :: Dispatch -> Config.Config -> (String -> IO ()) ->
                MVar (M.Map RequestId AppliedCommand) -> Int -> MVar PublishedConsensus -> IO ()
runApiServer dispatch conf logFn appliedMap port mPubConsensus' = do
  putStrLn $ "runApiServer: starting on port " ++ show port
  nextRidFun <- mkNextRequestId
  httpServe (serverConf port) $
    applyCORS defaultOptions $ methods [GET, POST] $
    route [ ("api", runReaderT api (ApiEnv appliedMap logFn dispatch conf mPubConsensus' nextRidFun))]

api :: Api ()
api = route [
       ("public",sendPublic)
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
  b <- readRequestBody 1000000
  let r = eitherDecode b
  case r of
    Right v -> return (toStrict b,v)
    Left e -> die 400 (BS.pack e)

setJSON :: Api ()
setJSON = modifyResponse $ setHeader "Content-Type" "application/json"

writeResponse :: ToJSON j => j -> Api ()
writeResponse j = setJSON >> writeLBS (encode j)

sendPublic :: Api ()
sendPublic = do
  (bs,_) :: (BS.ByteString,PactRPC) <- readJSON
  rid <- view aiNextRequestId >>= \f -> liftIO f
  nid <- view (aiConfig.nodeId)
  enqueueRPC $ CMD' (Command (CommandEntry . SZ.encode . PublicMessage $ bs) nid rid Valid NewMsg)
  writeResponse $ object [ "status" .= pack "Success", "requestId" .= rid ]

poll :: Api ()
poll = do
  (_,rid) <- fmap requestId <$> readJSON
  r <- view aiApplied >>= liftIO . tryReadMVar >>= fromMaybeM (die 500 "Results unavailable") <&> M.lookup rid
  case r of
    Nothing -> writeResponse $ object ["status" .= pack "Failure", "message" .= pack "Response not found"]
    Just (AppliedCommand (CommandResult cr) _lat _) -> setJSON >> writeBS cr

serverConf :: MonadSnap m => Int -> Snap.Config m a
serverConf port = setErrorLog (ConfigFileLog "log/error.log") $
                  setAccessLog (ConfigFileLog "log/access.log") $
                  setPort port defaultConfig


enqueueRPC :: RPC -> Api ()
enqueueRPC m = do
  env <- ask
  conf <- return (_aiConfig env)
  PublishedConsensus {..} <- fromMaybeM (die 500 "Invariant error: consensus unavailable") =<<
                               liftIO (tryReadMVar (_aiPubConsensus env))
  ldr <- fromMaybeM (die 500 "System unavaiable, please try again later") _pcLeader
  signedRPC <- return $ rpcToSignedRPC (_nodeId conf)
                        (Config._myPublicKey conf) (Config._myPrivateKey conf) m -- TODO
  if _nodeId conf == ldr
  then do -- dispatch internally if we're leader, otherwise send outbound
    ts <- liftIO getCurrentTime
    liftIO $ writeComm (_inboundCMD $ _aiDispatch env) $ InboundCMD (ReceivedAt ts, signedRPC)
  else liftIO $ writeComm (_outboundGeneral $ _aiDispatch env) $
       directMsg [(ldr,SZ.encode signedRPC)]


{-
clientSendRPC :: NodeId -> RPC -> Consensus ()
clientSendRPC target rpc = do
  send <- view clientSendMsg
  myNodeId' <- viewConfig nodeId
  privKey <- viewConfig myPrivateKey
  pubKey <- viewConfig myPublicKey
  sRpc <- return $ rpcToSignedRPC myNodeId' pubKey privKey rpc
  debug $ "Issuing direct msg: " ++ show (_digType $ _sigDigest sRpc) ++ " to " ++ show (unAlias $ _alias target)
  liftIO $! send $! directMsg [(target, encode sRpc)]
-}
