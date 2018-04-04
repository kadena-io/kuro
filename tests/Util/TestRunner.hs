{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}

module Util.TestRunner 
  ( delTempFiles
  , runAll
  , testDir
  , testConfDir) where 

import Apps.Kadena.Client   
import Control.Concurrent
import Control.Exception.Safe
import Control.Monad
import Control.Monad.Trans.RWS.Lazy
import Data.Aeson hiding (Success)
import Data.Default
import qualified Data.HashMap.Strict as HM
import qualified Data.Yaml as Y
import Pact.ApiReq
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

runAll :: IO ()
runAll = do
  procHandles <- runServers 
  putStrLn $ "Servers are running, sleeping for 3 seconds"
  _ <- sleep 3
  catchAny (do 
             runClientCommands clientArgs
             stopProcesses procHandles) 
           (\_ -> stopProcesses procHandles)
  
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
stopProcesses handles = do
    mapM_ terminateProcess handles
    return ()

serverArgs :: [String]      
serverArgs = [serverArgs0, serverArgs1, serverArgs2, serverArgs3]

serverArgs0, serverArgs1, serverArgs2, serverArgs3 :: String
serverArgs0 = "+RTS -N4 -RTS -c " ++ testConfDir ++ "10000-cluster.yaml"
serverArgs1 = "+RTS -N4 -RTS -c " ++ testConfDir ++ "10001-cluster.yaml"
serverArgs2 = "+RTS -N4 -RTS -c " ++ testConfDir ++ "10002-cluster.yaml"
serverArgs3 = "+RTS -N4 -RTS -c " ++ testConfDir ++ "10003-cluster.yaml"

clientArgs :: [String]
clientArgs = words $ "-c " ++ testConfDir ++ "client.yaml"

runClientCommands :: [String] -> IO ()
runClientCommands args = 
  case getOpt Permute coptions args of
    (_,_,es@(_:_)) -> print es >> exitFailure
    (o,_,_) -> do
      let opts = foldl (flip id) def o
      i <- newMVar =<< initRequestId
      (conf :: ClientConfig) <- either (\e -> print e >> exitFailure) return 
        =<< (Y.decodeFileEither (_oConfig opts))
      cmdLines <- readCmdLines
      -- void $ runStateT (runReaderT (simpleRunREPL cmdLines) conf) $ ReplState
      _ <- runRWST (simpleRunREPL cmdLines) conf ReplState
       {
          _server = fst (minimum $ HM.toList (_ccEndpoints conf)),
          _batchCmd = "\"Hello Kadena\"",
          _requestId = i,
          _cmdData = Null,
          _keys = [KeyPair (_ccSecretKey conf) (_ccPublicKey conf)],
          _fmt = Table,
          _echo = False
        }
      return ()

simpleRunREPL :: [String] -> Repl ()
simpleRunREPL [] = return ()
simpleRunREPL (x:xs) =
  case parseString parseCliCmd mempty x of 
    Failure (ErrInfo e _) -> do 
      flushStrLn $ "Parse failure (help for command help):\n" ++ show e
      return () 
    Success c -> do
      handleCmd c 
      {-
      liftIO $ putStrLn "--------------------------------------------------------------------------------"
      url <- ask getServer
      liftIO $ putStrLn $ "Server URL: " ++ url
      s <- get 
      liftIO $ putStrLn $ "batchCmnd: " ++ show (_batchCmd s) 
      liftIO $ putStrLn $ "cmdData: " ++ show (_cmdData s)
      liftIO $ putStrLn "--------------------------------------------------------------------------------\n"
      -}
      simpleRunREPL xs 

readCmdLines :: IO [String]
-- readCmdLines = fmap lines . readFile $ testDir ++ "commands.txt"
readCmdLines = fmap (filter (/= "") . lines) (readFile (testDir ++ "commands.txt")) 
