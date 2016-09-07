{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}

module Apps.Kadena.Client
  ( main
  ) where

import Control.Monad.State
import Control.Lens
import Control.Monad.Catch
import Control.Concurrent.Lifted (threadDelay)

import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Maybe (fromJust, fromMaybe)
import qualified Data.HashMap.Strict as HMap
import Data.Either ()
import Data.Aeson hiding ((.=))
import Data.Aeson.Lens
import Data.Aeson.Types hiding ((.=),parse)
import qualified Data.Yaml as Y
import Text.Read (readMaybe)
import qualified Data.Text as T

import Network.Wreq
import System.IO
import GHC.Int (Int64)

import Kadena.Types.Base
import Kadena.Command.Types
import Kadena.Types.Api

data ReplState = ReplState {
      _server :: String
    , _batchCmd :: String
}
makeLenses ''ReplState

prompt :: String -> String
prompt s = "\ESC[0;31m" ++ s ++ ">> \ESC[0m"

flushStr :: MonadIO m => String -> m ()
flushStr str = liftIO (putStr str >> hFlush stdout)

flushStrLn :: MonadIO m => String -> m ()
flushStrLn str = liftIO (putStrLn str >> hFlush stdout)

readPrompt :: StateT ReplState IO (Maybe String)
readPrompt = do
  use server >>= flushStr . prompt
  e <- liftIO $ isEOF
  if e then return Nothing else Just <$> liftIO getLine

_run :: StateT ReplState m a -> m (a, ReplState)
_run a = runStateT a (ReplState "localhost:8000" "(demo.transfer \"Acct1\" \"Acct2\" (% 1 1))")

sendCmd :: String -> StateT ReplState IO ()
sendCmd cmd = do
  s <- use server
  r <- liftIO $ post ("http://" ++ s ++ "/api/public/send") (toJSON (Exec (ExecMsg (T.pack cmd) Null)))
  rids <- view (responseBody.ssRequestIds) <$> asJSON r
  showResult 10000 rids Nothing

batchTest :: Int -> String -> StateT ReplState IO ()
batchTest n cmd = do
  s <- use server
  r <- liftIO $ post ("http://" ++ s ++ "/api/public/batch") (toJSON (Batch (replicate n (Exec (ExecMsg (T.pack cmd) Null)))))
  rids <- view (responseBody.ssRequestIds) <$> asJSON r
  showResult (n * 200) rids (Just (fromIntegral n))

manyTest :: Int -> String -> StateT ReplState IO ()
manyTest n cmd = do
  s <- use server
  rs <- replicateM n $ liftIO $ post ("http://" ++ s ++ "/api/public/send") (toJSON (Exec (ExecMsg (T.pack cmd) Null)))
  rids <- view (responseBody.ssRequestIds) <$> asJSON (last rs)
  showResult (n * 200) rids (Just (fromIntegral n))

setup :: StateT ReplState IO ()
setup = do
  code <- T.pack <$> liftIO (readFile "demo/demo.pact")
  (ej :: Either String Value) <- eitherDecode <$> liftIO (BSL.readFile "demo/demo.json")
  case ej of
    Left err -> liftIO (flushStrLn $ "ERROR: demo.json file invalid: " ++ show err)
    Right j -> do
      s <- use server
      r <- liftIO $ post ("http://" ++ s ++ "/api/public/send") (toJSON (Exec (ExecMsg code j)))
      rids <- view (responseBody.ssRequestIds) <$> asJSON r
      showResult 10000 rids Nothing





showResult :: Int -> [RequestId] -> Maybe Int64 -> StateT ReplState IO ()
showResult _ [] _ = return ()
showResult tdelay rids countm = loop (0 :: Int) where
    loop c = do
      threadDelay tdelay
      when (c > 100) $ flushStrLn "Timeout"
      s <- use server
      r <- liftIO $ post ("http://" ++ s ++ "/api/poll") (toJSON (PollRequest [last rids]))
      v <- asValue r
      case toListOf (responseBody.key "responses".values) v of
        [] -> flushStrLn $ "Error: no results received: " ++ show r
        rs -> case parseEither parseJSON (last rs) of
            Right (PollSuccessEntry lat rsp) ->
                case countm of
--                  Nothing -> flushStrLn (BS8.unpack (Y.encode rsp))
                  Nothing -> flushStrLn $ fromMaybe (BS8.unpack (Y.encode rsp)) (pprintBalances rsp)
                  Just cnt -> flushStrLn $ intervalOfNumerous cnt lat
            Left _ ->  loop (succ c)


pprintBalances :: Value -> Maybe String
pprintBalances v = do
  let headerRow =    "Account   | Balance      | Last Change  | Data Payload\n"
                  ++ "------------------------------------------------------\n"
      acctRow acctName v' = do
        amt <- v' ^? key "amount" >>= return . (filter (\a -> a /= '\n' && a /= '.')) . BS8.unpack . Y.encode >>= \v2 -> return $ v2 ++ take (12 - length v2) (repeat ' ')
        lastChange <- v' ^? key "balance" >>= return . (filter (\a -> a /= '\n' && a /= '.')) . BS8.unpack . Y.encode >>= \v2 -> return $ v2 ++ take (12 - length v2) (repeat ' ')
        dataPay <- v' ^? key "data" >>= return . (filter (\a -> a /= '\n' && a /= '.')) . BS8.unpack . Y.encode
        return $ acctName ++ " | " ++ lastChange ++ " | " ++ amt ++ " | " ++ dataPay ++ "\n"
  (res :: Value) <- v ^? key "result"
  case res of
    Object res' | HMap.size res' == 2 -> do
      acct1 <- (res ^? key "Acct1") >>= acctRow "Acct1    "
      acct2 <- (res ^? key "Acct2") >>= acctRow "Acct2    "
      return $ headerRow ++ acct1 ++ acct2
    _ -> Nothing

_sampleBalances :: Value
_sampleBalances = fromJust $ decode "{\"status\": \"Success\",\"result\": {\"Acct1\": {\"amount\": \"-1%1\",\"data\": {\"transfer-to\": \"Acct2\"},\"balance\": \"87000%1\"},\"Acct2\": {\"amount\": \"1%1\",\"data\": {\"transfer-from\": \"Acct1\"},\"balance\": \"13000%1\"}}}"


runREPL :: StateT ReplState IO ()
runREPL = loop True
  where
    loop go =
        when go $ catch run (\(SomeException e) ->
                             flushStrLn ("Exception: " ++ show e) >> loop True)
    run = do
      cmd' <- readPrompt
      case cmd' of
        Nothing -> loop False
        Just cmd -> parse cmd >> loop True
    parse cmd = do
      bcmd <- use batchCmd
      case cmd of
        "sleep" -> threadDelay 5000000
        "cmd?" -> use batchCmd >>= flushStrLn
        "setup" -> setup
        _ | take 11 cmd == "batch test:" ->
            case readMaybe $ drop 11 cmd of
              Just n -> batchTest n bcmd
              Nothing -> return ()
          | take 10 cmd == "many test:" ->
              case readMaybe $ drop 10 cmd of
                Just n -> manyTest n bcmd
                Nothing -> return ()
          | take 7 cmd == "server:" ->
              server .= drop 7 cmd
          | take 4 cmd == "cmd:" ->
              batchCmd .= drop 4 cmd
          | otherwise ->  sendCmd cmd



intervalOfNumerous :: Int64 -> Int64 -> String
intervalOfNumerous cnt mics = let
  interval' = fromIntegral mics / 1000000
  perSec = ceiling (fromIntegral cnt / interval')
  in "Completed in " ++ show (interval' :: Double) ++ "sec (" ++ show (perSec::Integer) ++ " per sec)"


main :: IO ()
main = void $ _run runREPL
