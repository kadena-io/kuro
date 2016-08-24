{-# LANGUAGE OverloadedStrings #-}

module Apps.Juno.ApiHandlers
  ( apiRoutes
  , ApiEnv(..)
  ) where

import Control.Concurrent.Chan.Unagi
import Control.Concurrent.MVar (readMVar)
import Control.Monad.Reader
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Text as T
import qualified Data.Map as Map
import Data.Map (Map)
import qualified Data.Aeson as JSON
import Snap.Core
import System.Posix.Files
import Apps.Juno.JsonTypes
import Juno.Types hiding (CommandBatch)


data ApiEnv = ApiEnv {
      _aiToCommands :: InChan (RequestId, [(Maybe Alias, CommandEntry)]),
      _aiCmdStatusMap :: CommandMVarMap
}

apiRoutes :: ReaderT ApiEnv Snap ()
apiRoutes = route [
              ("api/juno/v1/transact", apiWrapper transact)
             --,("api/juno/v1/local", apiWrapper local)
             --,("api/juno/v1/cmd/batch", cmdBatch)
             ,("api/juno/v1/poll", pollForResults)
            ,("ui",serveUI)
             ]

serveUI :: MonadSnap m => m ()
serveUI = do
  p <- (("demoui/public/"++) . BSC.unpack . rqPathInfo) <$> getRequest
  e <- liftIO $ fileExist p
  if e then sendFile p else withResponse $ \r -> do
            writeBS "Error 404: Not Found"
            liftIO $ putStrLn $ "Error 404: Not Found: " ++ p
            finishWith (setResponseStatus 404 "Not Found" r)


apiWrapper :: (BLC.ByteString -> Either BLC.ByteString [CommandEntry]) -> ReaderT ApiEnv Snap ()
apiWrapper requestHandler = do
   modifyResponse $ setHeader "Content-Type" "application/json"
   reqBytes <- readRequestBody 1000000
   case requestHandler reqBytes of
     Right cmdEntries -> do
         env <- ask
         reqestId@(RequestId rId) <- liftIO $ setNextCmdRequestId (_aiCmdStatusMap env)
         liftIO $ writeChan (_aiToCommands env) (reqestId, (\c -> (Nothing, c)) <$> cmdEntries)
         (writeBS . BLC.toStrict . JSON.encode) $ commandResponseSuccess ((T.pack . show) rId) ""
     Left err -> writeBS $ BLC.toStrict err


transact :: BLC.ByteString -> Either BLC.ByteString [CommandEntry]
transact = Right . (:[]) . CommandEntry . BLC.toStrict

-- TODO: _aiCmdStatusMap needs to be updated by Juno protocol this is never updated
-- poll for a list of cmdIds, returning the applied results or error
-- see juno/jmeter/juno_API_jmeter_test.jmx
pollForResults :: ReaderT ApiEnv Snap ()
pollForResults = do
    maybePoll <- JSON.decode <$> readRequestBody 1000000
    modifyResponse $ setHeader "Content-Type" "application/json"
    case maybePoll of
      Just (PollPayloadRequest (PollPayload cmdids) _) -> do
        env <- ask
        (CommandMap _ m) <- liftIO $ readMVar (_aiCmdStatusMap env)
        let rids = (RequestId . read . T.unpack) <$> cleanInput cmdids
        let results = PollResponse $ fmap (toRepresentation . flipIt m) rids
        writeBS . BLC.toStrict $ JSON.encode results
      Nothing -> writeBS . BLC.toStrict . JSON.encode $ commandResponseFailure "" "Malformed input, could not decode input JSON."
  where
    -- for now allow "" (empty) cmdIds
    cleanInput = filter (/=T.empty)

    flipIt :: Map RequestId CommandStatus ->  RequestId -> Maybe (RequestId, CommandStatus)
    flipIt m rId = (fmap . fmap) (\cmd -> (rId, cmd)) (`Map.lookup` m) rId

    toRepresentation :: Maybe (RequestId, CommandStatus) -> PollResult
    toRepresentation (Just (RequestId rid, cmdStatus)) =
        cmdStatus2PollResult (RequestId rid) cmdStatus
    toRepresentation Nothing = cmdStatusError
