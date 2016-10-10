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
import Kadena.Command.Types
import Kadena.Types.Command
import Kadena.HTTP.Types

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
    , _requestId :: Int64
    , _requestKey :: RequestKey
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
  requestId %= succ
  rid <- use requestId
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
  flushStrLn $ "Prepared " ++ show (length es') ++ " messages ..."
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
      r <- liftIO $ post ("http://" ++ s ++ "/api/poll") (toJSON (Poll [last rks]))
      resp <- asJSON r
      case resp ^. responseBody of
        ApiFailure err -> flushStrLn $ "Error: no results received: " ++ show err
        ApiSuccess [] -> loop $ c + 1
        ApiSuccess [PollResult{..}] ->
                case countm of
                  Nothing -> do
                    prettyRes <- return $ (pprintResult =<< decode (BSL.fromStrict $ unCommandResult _prResponse))
                    case prettyRes of
                      Just r' -> flushStrLn r'
                      Nothing -> do
                        uglyRes <- return $ fromMaybe (Y.String "unable to decode") (Y.decode $ unCommandResult _prResponse)
                        flushStrLn $ BS8.unpack $ Y.encode uglyRes
                  Just cnt -> flushStrLn $ intervalOfNumerous cnt _prLatency
        v -> flushStrLn $ "Error: " ++ show v

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
        ":sleep" -> threadDelay 5000000
        "?cmd" -> use batchCmd >>= flushStrLn
        "?servers" -> view ccEndpoints >>= liftIO . mapM_ print
        ":setup" -> setup
        _ | take 7 cmd == ":batch " ->
            case readMaybe $ drop 7 cmd of
              Just n -> batchTest n bcmd
              Nothing -> return ()
          | take 8 cmd == ":server " ->
              server .= drop 8 cmd
          | take 5 cmd == ":cmd " ->
              batchCmd .= drop 5 cmd
          | otherwise ->  sendCmd cmd


_run :: StateT ReplState m a -> m (a, ReplState)
_run a = runStateT a (ReplState "localhost:8000" "(demo.transfer \"Acct1\" \"Acct2\" 1.00)" 0 initialRequestKey)



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
         i <- initRequestId
         (conf :: ClientConfig) <- either (\e -> print e >> exitFailure) return =<< Y.decodeFileEither (_oConfig opts)
         void $ runStateT (runReaderT runREPL conf)
                  (ReplState (snd (head (HM.toList (_ccEndpoints conf))))
                             "(demo.transfer \"Acct1\" \"Acct2\" 1.00)"
                             i
                             initialRequestKey)
