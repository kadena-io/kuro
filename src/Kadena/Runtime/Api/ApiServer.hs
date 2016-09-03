{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Runtime.Api.ApiServer
    where
import Control.Concurrent.Chan.Unagi
import Control.Monad.Reader
import Data.Aeson hiding (defaultOptions)
import qualified Data.ByteString.Char8 as BS
import Control.Lens
import Data.Monoid
import Prelude hiding (log)

import Snap.Http.Server as Snap
import Snap.Core
import Snap.CORS

import Kadena.Types.Command
import Kadena.Types.Base
import Kadena.Types.Comms
import Kadena.Types.Message
import Kadena.Types.Event
import Kadena.Types.Service.Sender
import Kadena.Types.Config as Config


data ApiEnv = ApiEnv {
      _aiToCommands :: InChan (RequestId, [CommandEntry])
    , _aiCmdStatusMap :: CommandMVarMap
    , _aiLog :: String -> IO ()
    , _aiEvents :: SenderServiceChannel
    , _aiConfig :: Config.Config
}
makeLenses ''ApiEnv


runApiServer :: SenderServiceChannel -> Config.Config -> (String -> IO ()) -> InChan (RequestId, [CommandEntry]) -> CommandMVarMap -> Int -> IO ()
runApiServer chan conf logFn toCommands sharedCmdStatusMap port = do
  putStrLn "Starting up server runApiServer"
  httpServe (serverConf port) $
    applyCORS defaultOptions $ methods [GET, POST] $
    route [ ("api", runReaderT api (ApiEnv toCommands sharedCmdStatusMap logFn chan conf))]

api :: ReaderT ApiEnv Snap ()
api = route [
              ("send-public",sendPublic)
             ]

log :: String -> ReaderT ApiEnv Snap ()
log s = view aiLog >>= \f -> liftIO (f s)

die :: Int -> BS.ByteString -> ReaderT ApiEnv Snap t
die code msg = do
  let s = "Error " <> BS.pack (show code) <> ": " <> msg
  writeBS s
  log (BS.unpack s)
  withResponse (finishWith . setResponseStatus code "Error")

readJSON :: FromJSON t => ReaderT ApiEnv Snap t
readJSON = do
  r <- eitherDecode <$> readRequestBody 1000000
  case r of
    Right v -> return v
    Left e -> die 400 (BS.pack e)

sendPublic :: ReaderT ApiEnv Snap ()
sendPublic = undefined


serverConf :: MonadSnap m => Int -> Snap.Config m a
serverConf port = setErrorLog (ConfigFileLog "log/error.log") $
                  setAccessLog (ConfigFileLog "log/access.log") $
                  setPort port defaultConfig


{-
enqueueRPC :: RPC -> ReaderT ApiEnv Snap ()
enqueueRPC m = do
  env <- ask
  let conf = _aiConfig env
      signed = rpcToSignedRPC (_nodeId conf) (_myPublicKey conf) (_myPrivateKey conf) m
  liftIO $ writeComm (_aiEvents env) (InternalEvent (ERPC signed))
-}

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
