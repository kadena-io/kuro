{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}

module Apps.Kadena.Client
  ( main,ClientConfig(..)
  ) where

import Control.Monad.State
import Control.Monad.Reader
import Control.Lens
import Control.Monad.Catch
import Control.Concurrent.Lifted (threadDelay)
import Control.Concurrent.MVar

import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Maybe (fromJust, fromMaybe)
import qualified Data.HashMap.Strict as HM
import Data.Either ()
import Data.Aeson hiding ((.=), Result(..), Value(..))
import Data.Aeson.Lens
import Data.Aeson.Types hiding ((.=),parse, Result(..))
import qualified Data.Yaml as Y
import Text.Read (readMaybe)
import qualified Data.Text as T
import Data.Foldable
import Data.List
import System.Environment
import System.Exit
import System.Console.GetOpt
import Data.Default
import Data.Thyme.Clock
import Data.Thyme.Time.Core (unUTCTime, toMicroseconds)

import Network.Wreq
import System.IO
import GHC.Generics
import Data.Int

import Kadena.Types.Base
import Kadena.Types.Command

data ClientOpts = ClientOpts {
      _oConfig :: FilePath
}
makeLenses ''ClientOpts
instance Default ClientOpts where def = ClientOpts ""


coptions :: [OptDescr (ClientOpts -> ClientOpts)]
coptions =
  [ Option ['c']
           ["config"]
           (ReqArg (\fp -> set oConfig fp) "config")
           "Configuration File"
  ]

data ClientConfig = ClientConfig {
      _ccAlias :: Alias
    , _ccSecretKey :: PrivateKey
    , _ccPublicKey :: PublicKey
    , _ccEndpoints :: HM.HashMap String String
    } deriving (Eq,Show,Generic)
makeLenses ''ClientConfig
instance ToJSON ClientConfig where
  toJSON = genericToJSON defaultOptions { fieldLabelModifier = drop 3 }
instance FromJSON ClientConfig where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = drop 3 }

data ReplState = ReplState {
      _server :: String
    , _batchCmd :: String
    , _requestId :: MVar Int64 -- this needs to be an MVar in case we get an exception mid function... it's our entropy
}
makeLenses ''ReplState

type Repl a = ReaderT ClientConfig (StateT ReplState IO) a

prompt :: String -> String
prompt s = "\ESC[0;31m" ++ s ++ ">> \ESC[0m"

flushStr :: MonadIO m => String -> m ()
flushStr str = liftIO (putStr str >> hFlush stdout)

flushStrLn :: MonadIO m => String -> m ()
flushStrLn str = liftIO (putStrLn str >> hFlush stdout)

readPrompt :: Repl (Maybe String)
readPrompt = do
  use server >>= flushStr . prompt
  e <- liftIO $ isEOF
  if e then return Nothing else Just <$> liftIO getLine

mkExec :: String -> Value -> Repl PactMessage
mkExec code mdata = do
  sk <- view ccSecretKey
  pk <- view ccPublicKey
  a <- view ccAlias
  rid <- use requestId >>= liftIO . (`modifyMVar` (\i -> return $ (succ i, i)))
  return $ mkPactMessage sk pk a (show rid) (Exec (ExecMsg (T.pack code) mdata))

sendCmd :: String -> Repl ()
sendCmd cmd = do
  s <- use server
  (e :: PactMessage) <- mkExec cmd Null
  r <- liftIO $ post ("http://" ++ s ++ "/api/public/send") (toJSON $ SubmitBatch [e])
  resp <- asJSON r
  case resp ^. responseBody of
    ApiFailure{..} -> do
      flushStrLn $ "Failure: " ++ show _apiError
    ApiSuccess{..} -> do
      rk <- return $ head $ _rkRequestKeys _apiResponse
      flushStrLn $ "Request Id: " ++ show rk
      showResult 10000 [rk] Nothing

batchTest :: Int -> String -> Repl ()
batchTest n cmd = do
  s <- use server
  es@(SubmitBatch es') <- SubmitBatch <$> replicateM n (mkExec cmd Null)
  flushStrLn $ "Preparing " ++ show (length es') ++ " messages ..."
  r <- liftIO $ post ("http://" ++ s ++ "/api/public/send") (toJSON es)
  flushStrLn $ "Sent, retrieving responses"
  resp <- asJSON r
  case resp ^. responseBody of
    ApiFailure{..} -> do
      flushStrLn $ "Failure: " ++ show _apiError
    ApiSuccess{..} -> do
      rk <- return $ last $ _rkRequestKeys _apiResponse
      flushStrLn $ "Polling for RequestKey: " ++ show rk
      showResult 10000 [rk] (Just (fromIntegral n))

setup :: Repl ()
setup = do
  code <- liftIO (readFile "demo/demo.pact")
  (ej :: Either String Value) <- eitherDecode <$> liftIO (BSL.readFile "demo/demo.json")
  case ej of
    Left err -> liftIO (flushStrLn $ "ERROR: demo.json file invalid: " ++ show err)
    Right j -> do
      s <- use server
      e <- mkExec code j
      r <- liftIO $ post ("http://" ++ s ++ "/api/public/send") (toJSON $ SubmitBatch [e])
      resp <- asJSON r
      case resp ^. responseBody of
        ApiFailure{..} -> do
          flushStrLn $ "Failure: " ++ show _apiError
        ApiSuccess{..} -> do
          rk <- return $ head $ _rkRequestKeys _apiResponse
          flushStrLn $ "Request Key: " ++ show rk
          showResult 10000 [rk] Nothing

showResult :: Int -> [RequestKey] -> Maybe Int64 -> Repl ()
showResult _ [] _ = return ()
showResult tdelay rks countm = loop (0 :: Int)
  where
    loop c = do
      threadDelay tdelay
      when (c > 100) $ flushStrLn "Timeout"
      s <- use server
      r <- liftIO $ post ("http://" ++ s ++ "/api/listen") (toJSON (ListenerRequest $ last rks))
      resp <- asJSON r
      case resp ^. responseBody of
        ApiFailure err -> flushStrLn $ "Error: no results received: " ++ show err
        ApiSuccess PollResult{..} ->
                case countm of
                  Nothing -> do
                    prettyRes <- return $ (pprintResult =<< decode (BSL.fromStrict $ unCommandResult _prResponse))
                    case prettyRes of
                      Just r' -> flushStrLn r'
                      Nothing -> do
                        uglyRes <- return $ fromMaybe (Y.String "unable to decode") (Y.decode $ unCommandResult _prResponse)
                        flushStrLn $ BS8.unpack $ Y.encode uglyRes
                  Just cnt -> flushStrLn $ intervalOfNumerous cnt _prLatency

pollForResult :: RequestKey -> Repl ()
pollForResult rk = do
  s <- use server
  r <- liftIO $ post ("http://" ++ s ++ "/api/poll") (toJSON (Poll [rk]))
  resp <- asJSON r
  case resp ^. responseBody of
    ApiFailure err -> flushStrLn $ "Error: no results received: " ++ show err
    ApiSuccess (res::[PollResult]) -> mapM_ (\PollResult{..} -> do
      prettyRes <- return $ (pprintResult =<< decode (BSL.fromStrict $ unCommandResult _prResponse))
      case prettyRes of
        Just r' -> flushStrLn r'
        Nothing -> do
          uglyRes <- return $ fromMaybe (Y.String "unable to decode") (Y.decode $ unCommandResult _prResponse)
          flushStrLn $ BS8.unpack $ Y.encode uglyRes) res

pprintResult :: Value -> Maybe String
pprintResult v = do
  let valKeys rs = either (const Nothing) id $ foldl' checkKeys (Right Nothing) rs
      checkKeys (Right Nothing) (Object o) = Right $ Just $ sort $ HM.keys o
      checkKeys r@(Right (Just ks)) (Object o) | sort (HM.keys o) == ks = r
      checkKeys _ _ = Left ()
      fill l s = s ++ replicate (l - length s) ' '
      colwidth = 12
      colify cw ss = intercalate " | " (map (fill cw) ss)
      render = BSL.unpack . encode
  o <- return $ toListOf (key "result" . values) v
  ks <- valKeys o
  h1 <- return $ colify colwidth (map T.unpack ks)
  hr <- return $ replicate (length h1) '-'
  rows <- return $ (`map` o) $ \(Object r) ->
          intercalate " | " (map (fill colwidth . render . (r HM.!)) ks)
  return (intercalate "\n" (h1:hr:rows))


_s2 :: Value
_s2 = fromJust $ decode "{\"status\":\"Success\",\"result\":[{\"amount\":100000.0,\"data\":\"Admin account funding\",\"balance\":100000.0,\"account\":\"Acct1\"},{\"amount\":0.0,\"data\":\"Created account\",\"balance\":0.0,\"account\":\"Acct2\"}]}"



runREPL :: Repl ()
runREPL = loop True
  where
    loop go =
        when go $ catch run (\(SomeException e) ->
                             flushStrLn ("Exception: " ++ show e) >> loop True)
    run = do
      cmd' <- readPrompt
      case cmd' of
        Nothing -> loop False
        Just "" -> loop True
        Just ":exit" -> loop False
        Just cmd -> parse cmd >> loop True
    parse cmd = do
      bcmd <- use batchCmd
      case cmd of
        ":help" -> help
        ":?" -> help
        "?" -> help
        ":sleep" -> threadDelay 5000000
        "?cmd" -> use batchCmd >>= flushStrLn
        "?servers" -> view ccEndpoints >>= liftIO . mapM_ print
        ":setup" -> setup
        _ | take 7 cmd == ":batch " ->
            case readMaybe $ drop 7 cmd of
              Just n | n <= 50000 -> batchTest n bcmd
                     | otherwise -> void $ flushStrLn "batch test is limited to a maximum of 50k transactions at a time."
              Nothing -> return ()
        _ | take 6 cmd == ":poll " -> do
              b <- return $ B16.decode $ BS8.pack $ drop 6 cmd
              case b of
                (rk,leftovers)
                  | B.empty /= leftovers -> void $ flushStrLn $ "Failed to decode RequestKey: this was converted " ++ show rk ++ " and this was not " ++ show leftovers
                  | B.length rk /= hashLengthAsBS -> void $ flushStrLn $ "RequestKey is too short, should be "
                                                              ++ show hashLengthAsBase16
                                                              ++ " char long but was " ++ show (B.length $ BS8.pack $ drop 7 cmd) ++ " -> " ++ show (B16.encode rk)
                  | otherwise -> void $ pollForResult $ RequestKey $ Hash $ rk
          | take 8 cmd == ":server " ->
              server .= drop 8 cmd
          | take 5 cmd == ":cmd " ->
              batchCmd .= drop 5 cmd
          | otherwise ->  sendCmd cmd

help :: Repl ()
help = flushStrLn
  "Kadena Client -- Payments Demo -- Kadena LLC © (2016-2017) \n\
  \Commands: \n\
  \:setup - ready the payments demo by executing the ./demo/demo.pact smart contract to create the needed tables and modules \n\
  \       - NB: this command only needs to be run once and must be run for `(demo.read-all)` and `:batch N` to correctly function \n\
  \   127.0.0.1:8003>> :setup  \n\
  \   Request Key: \"94d1d46b991c293dbc94016d3d4fc7c7c97302d991458e907c5d6fccd97a32a6\"  \n\
  \   status: Success  \n\
  \   result: Write succeeded  \n\
  \\n\
  \<Query Accounts> - See <Pact-Code> example\n\
  \\n\
  \<Pact-Code> - Run a transaction containing arbitrary pact smart contract code \n\
  \   127.0.0.1:8003>> (demo.read-all) \n\
  \   Request Id: \"cba86abd875a332388215a826dae6036c7171a0dd4590d789593d3b97214409d\"  \n\
  \   account      | amount       | balance      | data  \n\
  \   ---------------------------------------------------------  \n\
  \   \"Acct1\"      | \"-1.00\"      | \"95000.00\"   | {\"transfer-to\":\"Acct2\"}  \n\
  \   \"Acct2\"      | \"1.00\"       | \"5000.00\"    | {\"transfer-from\":\"Acct1\"}  \n\
  \\n\
  \:poll <RequestKey> - poll kadena for historical transaction by RequestKey\n\
  \   127.0.0.1:8003>> :poll cba86abd875a332388215a826dae6036c7171a0dd4590d789593d3b97214409d\n\
  \   Request Id: \"cba86abd875a332388215a826dae6036c7171a0dd4590d789593d3b97214409d\"  \n\
  \   account      | amount       | balance      | data  \n\
  \   ---------------------------------------------------------  \n\
  \   \"Acct1\"      | \"-1.00\"      | \"95000.00\"   | {\"transfer-to\":\"Acct2\"}  \n\
  \   \"Acct2\"      | \"1.00\"       | \"5000.00\"    | {\"transfer-from\":\"Acct1\"}  \n\
  \\n\
  \:batch N - perform N single dollar individual transactions, print out performance results when finished\n\
  \           NB: performance results for N > 8000 are inaccurate, please contact info@kadena.io if more extensive testing is desired \n\
  \   127.0.0.1:8003>> :batch 5000\n\
  \   Prepared 5000 messages ...\n\
  \   Sent, retrieving responses\n\
  \   Polling for RequestKey: \"416bfaeb7871877f8aae2c5cd4672c5d157daa111fb7d3c5ca09d28a38624143\" \n\
  \   Completed in 0.478636sec (10447 per sec)  \n\
  \\n\
  \:server HOST:PORT - re-target the client to transact via the specified server\n\
  \   127.0.0.1:8003>> :server 127.0.0.1:8000\n\
  \   127.0.0.1:8000>>\n\
  \\n\
  \?cmd - print last command\n\
  \\n\
  \?servers - print configured server nodes' IP:PORT\n\
  \\n\
  \:exit - exit Repl\n\
  \:help | :? | ? - print out this document\n\
  \"


_run :: (Monad m, MonadIO m) => StateT ReplState m a -> m (a, ReplState)
_run a = liftIO (newMVar 1) >>= \mrid -> runStateT a (ReplState "localhost:8000" "(demo.transfer \"Acct1\" \"Acct2\" 1.00)" mrid)

intervalOfNumerous :: Int64 -> Int64 -> String
intervalOfNumerous cnt mics = let
  interval' = fromIntegral mics / 1000000
  perSec = ceiling (fromIntegral cnt / interval')
  in "Completed in " ++ show (interval' :: Double) ++ "sec (" ++ show (perSec::Integer) ++ " per sec)"

initRequestId :: IO Int64
initRequestId = do
  UTCTime _ time <- unUTCTime <$> getCurrentTime
  return $ toMicroseconds time

main :: IO ()
main = do
  as <- getArgs
  case getOpt Permute coptions as of
    (_,_,es@(_:_)) -> print es >> exitFailure
    (o,_,_) -> do
         let opts = foldl (flip id) def o
         i <- newMVar =<< initRequestId
         (conf :: ClientConfig) <- either (\e -> print e >> exitFailure) return =<< Y.decodeFileEither (_oConfig opts)
         void $ runStateT (runReaderT runREPL conf)
                  (ReplState (snd (head (HM.toList (_ccEndpoints conf))))
                             "(demo.transfer \"Acct1\" \"Acct2\" 1.00)"
                             i)
