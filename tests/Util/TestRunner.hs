{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Util.TestRunner 
  ( delTempFiles
  , runAll
  , testDir
  , testConfDir
  , TestRequest(..)
  , TestResponse(..)
  , TestResult(..)) where 

import Apps.Kadena.Client   
import Control.Concurrent
import Control.DeepSeq
import Control.Exception.Safe
import Control.Monad
import Control.Monad.Trans.RWS.Lazy
import Data.Aeson hiding (Success)
import Data.Default
import Data.List
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
                
data TestRequest = TestRequest 
  { cmd :: String 
  , matchCmd :: String -- used when the command as processed differs from the original command issued
                       -- e.g., the command "load myFile.yaml" is processed as "myFile.yaml"
                       -- FIXME: really need to find a better way to match these...
  , eval :: TestResponse -> Bool 
  , displayStr :: String 
  } deriving Generic
instance NFData TestRequest   

instance Show TestRequest where
  show tr = "cmd: " ++ cmd tr ++ "\nDisplay string: " ++ displayStr tr

data TestResponse = TestResponse
  { resultSuccess :: Bool
  , apiResultsStr :: String
  } deriving (Eq, Generic)
instance NFData TestResponse

instance Show TestResponse where 
  show tr = "resultSuccess: " ++ show (resultSuccess tr) ++ "\n" ++ take 100 (apiResultsStr tr) ++ "..."

data TestResult = TestResult 
  { requestTr :: TestRequest
  , responseTr :: Maybe TestResponse 
  } deriving (Generic, Show)
instance NFData TestResult

delTempFiles :: IO ()
delTempFiles = do
    let p = shell $ testDir ++ "deleteFiles.sh"
    _ <- createProcess p
    return ()

runAll :: [TestRequest] -> IO [TestResult]
runAll testRequests = do
  procHandles <- runServers 
  putStrLn "Servers are running, sleeping for 3 seconds"
  _ <- sleep 3
  catchAny (do 
              results <- runClientCommands clientArgs testRequests
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

runClientCommands :: [String] ->  [TestRequest] -> IO [TestResult]
runClientCommands args testRequests = do 
  putStrLn $ "runClientCommand with args: " ++ unlines args
  case getOpt Permute coptions args of
    (_,_,es@(_:_)) -> print es >> exitFailure
    (o,_,_) -> do
      let opts = foldl (flip id) def o
      i <- newMVar =<< initRequestId
      (conf :: ClientConfig) <- either (\e -> print e >> exitFailure) return 
        =<< Y.decodeFileEither (_oConfig opts)
      (_, _, w) <- runRWST (simpleRunREPL testRequests) conf ReplState
        { _server = fst (minimum $ HM.toList (_ccEndpoints conf))
        , _batchCmd = "\"Hello Kadena\""
        , _requestId = i
        , _cmdData = Null
        , _keys = [KeyPair (_ccSecretKey conf) (_ccPublicKey conf)]
        , _fmt = Table
        , _echo = False }
      putStrLn $ "Count of items in writer is: " ++ show (length w)
      buildResults testRequests w

buildResults :: [TestRequest] -> [ReplApiData] -> IO [TestResult]
buildResults testRequests ys = do
  let requests = filter isRequest ys
  let responses = filter (not . isRequest) ys
  let results = foldr (matchResponses requests responses) [] testRequests
  putStrLn $ "\nRequests: " ++ unlines (fmap show requests)  
  putStrLn $ "\nResponses: " ++ unlines (fmap show responses) 
  putStrLn $ "\nTestResults: " ++ unlines (fmap show results ) 
  return results

-- Fold function that matches a given TestRequest to:
--   a corresponding ReplApiRequest (matching via. the full text of the command)
--   a corresponding ReplApiResponse (matching via. requestKey))
-- and then builds a TestResult combining elements from both
matchResponses :: [ReplApiData] -> [ReplApiData] -> TestRequest -> [TestResult] -> [TestResult]
matchResponses [] _ _ acc = acc -- no requests
matchResponses _ [] _ acc = acc -- no responses
matchResponses requests@(ReplApiRequest _ _ : _)
               responses@(ReplApiResponse _ _ : _)
               testRequest acc = 
  let theApiRequest = find (\req -> _replCmd req == matchCmd testRequest) requests
      theApiResponse = case theApiRequest of 
        Nothing -> Nothing
        Just req -> find (\resp -> _apiResponseKey resp == _apiRequestKey req) responses
      testResponse =  theApiResponse >>= convertResponse         
  in case testResponse of
    Just _ -> TestResult
                { requestTr = testRequest
                , responseTr = testResponse
                } : acc
    Nothing -> acc
matchResponses _ _ _ acc = acc -- this shouldn't happen

convertResponse :: ReplApiData -> Maybe TestResponse
convertResponse (ReplApiResponse _ apiRslt) = 
  let str = show apiRslt
      ok = case _arResult apiRslt of 
        (Object ht) -> case HM.lookup (T.pack "status") ht of 
          Nothing -> False
          Just t -> t == "success" 
        _ -> False
  in Just TestResponse { resultSuccess = ok
                       , apiResultsStr = str } 
convertResponse _ = Nothing  -- this shouldn't happen 

isRequest :: ReplApiData -> Bool
isRequest (ReplApiRequest _ _) = True
isRequest (ReplApiResponse _ _) = False

simpleRunREPL :: [TestRequest] -> Repl ()
simpleRunREPL [] = return ()
simpleRunREPL (x:xs) = do
  let reqStr = cmd x
  case parseString parseCliCmd mempty reqStr of 
    Failure (ErrInfo e _) -> do 
      flushStrLn $ "Parse failure (help for command help):\n" ++ show e
      return () 
    Success c -> do
      handleCmd c reqStr 
      simpleRunREPL xs 
