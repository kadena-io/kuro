{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Util.TestRunner 
  ( delTempFiles
  , runAll
  , testDir
  , testConfDir
  , TestResult(..)) where 

import Apps.Kadena.Client   
import Control.Concurrent
import Control.DeepSeq
import Control.Exception.Safe
import Control.Monad
import Control.Monad.Trans.RWS.Lazy
import Data.Aeson hiding (Success)
import Data.Default
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import qualified Data.Yaml as Y
import GHC.Generics (Generic)
import Pact.ApiReq
import Pact.Types.API
import System.Command
import System.Console.GetOpt
import System.Time.Extra 
import Text.Trifecta (ErrInfo(..), parseString, Result(..))

testDir, testConfDir :: String
testDir = "test-files/"
testConfDir = "test-files/conf/"

delTempFiles :: IO ()
delTempFiles = do
    let p = shell $ testDir ++ "deleteFiles.sh"
    _ <- createProcess p
    return ()

runAll :: IO [TestResult]
runAll = do
  procHandles <- runServers 
  putStrLn "Servers are running, sleeping for 3 seconds"
  _ <- sleep 3
  catchAny (do 
              results <- runClientCommands clientArgs
              results `deepseq` stopProcesses procHandles
              return results)
           (\e -> do 
              stopProcesses procHandles
              throw e)
  
runServers :: IO [ProcessHandle]
runServers = 
  foldM f [] serverArgs where
    f acc x = do 
        h <- runServer x 
        return $ h : acc

runServer :: String -> IO ProcessHandle
runServer args = do
    let p = proc "kadenaserver" $ words args
    (_, _, _, procHandle) <- createProcess p
    sleep 1
    return procHandle

stopProcesses :: [ProcessHandle] -> IO ()
stopProcesses handles = mapM_ terminateProcess handles

serverArgs :: [String]      
serverArgs = [serverArgs0, serverArgs1, serverArgs2, serverArgs3]

serverArgs0, serverArgs1, serverArgs2, serverArgs3 :: String
serverArgs0 = "+RTS -N4 -RTS -c " ++ testConfDir ++ "10000-cluster.yaml"
serverArgs1 = "+RTS -N4 -RTS -c " ++ testConfDir ++ "10001-cluster.yaml"
serverArgs2 = "+RTS -N4 -RTS -c " ++ testConfDir ++ "10002-cluster.yaml"
serverArgs3 = "+RTS -N4 -RTS -c " ++ testConfDir ++ "10003-cluster.yaml"

clientArgs :: [String]
clientArgs = words $ "-c " ++ testConfDir ++ "client.yaml"

runClientCommands :: [String] -> IO [TestResult]
runClientCommands args = do 
  putStrLn $ "runClientCommand with args: " ++ unlines args
  case getOpt Permute coptions args of
    (_,_,es@(_:_)) -> print es >> exitFailure
    (o,_,_) -> do
      let opts = foldl (flip id) def o
      i <- newMVar =<< initRequestId
      (conf :: ClientConfig) <- either (\e -> print e >> exitFailure) return 
        =<< Y.decodeFileEither (_oConfig opts)
      cmdLines <- readCmdLines
      (_, _, w) <- runRWST (simpleRunREPL cmdLines) conf ReplState
        { _server = fst (minimum $ HM.toList (_ccEndpoints conf))
        , _batchCmd = "\"Hello Kadena\""
        , _requestId = i
        , _cmdData = Null
        , _keys = [KeyPair (_ccSecretKey conf) (_ccPublicKey conf)]
        , _fmt = Table
        , _echo = False }
      putStrLn $ "Count of items in writer is: " ++ show (length w)
      return $ fmap convertResult w

convertResult :: ApiResult -> TestResult
convertResult ar = 
  let str = show $ _arResult ar
      ok = case _arResult ar of 
        (Object ht) -> case HM.lookup (T.pack "status") ht of 
          Nothing -> False
          Just t -> t == "success" 
        _ -> False
      
  in TestResult { resultSuccess = ok
                , apiResultsStr = str } 
  
data TestResult = TestResult
  { resultSuccess :: Bool
  , apiResultsStr :: String
  --more to come... 
  } deriving Generic
instance NFData TestResult

simpleRunREPL :: [String] -> Repl ()
simpleRunREPL [] = return ()
simpleRunREPL (x:xs) =
  case parseString parseCliCmd mempty x of 
    Failure (ErrInfo e _) -> do 
      flushStrLn $ "Parse failure (help for command help):\n" ++ show e
      return () 
    Success c -> do
      handleCmd c 
      simpleRunREPL xs 

readCmdLines :: IO [String]
readCmdLines = fmap (filter (/= "") . lines) (readFile (testDir ++ "commands.txt")) 
