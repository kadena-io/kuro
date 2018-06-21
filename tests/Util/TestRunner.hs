{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Util.TestRunner
  ( delTempFiles
  , gatherMetrics
  , testDir
  , testConfDir
  , runClientCommands
  , runServers
  , runServersWith
  , stopProcesses
  , TestMetric(..)
  , TestMetricResult(..)
  , TestRequest(..)
  , TestResponse(..)
  , TestResult(..)) where

import Apps.Kadena.Client
import Control.Concurrent
import Control.Exception.Safe
import Control.Lens
import Control.Monad
import Control.Monad.Trans.RWS.Lazy
import Data.Aeson hiding (Success)
import qualified Data.ByteString.Lazy.Char8 as C8
import Data.Default
import Data.Int
import Data.List
import Data.List.Extra
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import qualified Data.Yaml as Y
import GHC.Generics (Generic)
import Network.Wreq
import qualified Network.Wreq as WR (getWith)
import Pact.ApiReq
import Pact.Types.API
import System.Command
import System.Console.GetOpt
import System.Time.Extra
import Text.Trifecta (ErrInfo(..), parseString, Result(..))

testDir, testConfDir, _testLogDir :: String
testDir = "test-files/"
testConfDir = "test-files/conf/"
_testLogDir = "test-files/log/"

data TestRequest = TestRequest
  { cmd :: String
  , matchCmd :: String -- used when the command as processed differs from the original command issued
                       -- e.g., the command "load myFile.yaml" is processed as "myFile.yaml"
                       -- FIXME: really need to find a better way to match these...
  , eval :: TestResponse -> Bool
  , displayStr :: String
  }

instance Show TestRequest where
  show tr = "cmd: " ++ cmd tr ++ "\nDisplay string: " ++ displayStr tr

data TestResponse = TestResponse
  { resultSuccess :: Bool
  , apiResult :: ApiResult
  , _batchCount :: Maybe Int64
  } deriving (Eq, Generic)

instance Show TestResponse where
  show tr = "resultSuccess: " ++ show (resultSuccess tr) ++ "\n"
    ++ "Batch count: " ++ show (_batchCount tr) ++ "\n"
    ++ take 100 (show (apiResult tr)) ++ "..."

data TestResult = TestResult
  { requestTr :: TestRequest
  , responseTr :: Maybe TestResponse
  } deriving Show

data TestMetric = TestMetric
  { metricNameTm :: String
  , evalTm :: String -> Bool
  }
instance Show TestMetric where
  show tm = show $ metricNameTm tm

data TestMetricResult = TestMetricResult
  { requestTmr :: TestMetric
  , valueTmr :: Maybe String
  } deriving Show

delTempFiles :: IO ()
delTempFiles = do
    let p = shell $ testDir ++ "deleteFiles.sh"
    _ <- createProcess p
    return ()

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

runClientCommands :: [String] ->  [TestRequest] -> IO [TestResult]
runClientCommands args testRequests =
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
      buildResults testRequests w

buildResults :: [TestRequest] -> [ReplApiData] -> IO [TestResult]
buildResults testRequests ys = do
  let requests = filter isRequest ys
  let responses = filter (not . isRequest) ys
  return $ foldr (matchResponses requests responses) [] testRequests

-- Fold function that matches a given TestRequest to:
--   a corresponding ReplApiRequest (matching via. the full text of the command)
--   a corresponding ReplApiResponse (matching via. requestKey))
-- and then builds a TestResult combining elements from both
matchResponses :: [ReplApiData] -> [ReplApiData] -> TestRequest -> [TestResult] -> [TestResult]
matchResponses [] _ _ acc = acc -- no requests
matchResponses _ [] _ acc = acc -- no responses
matchResponses requests@(ReplApiRequest _ _ : _)
               responses@(ReplApiResponse{}: _)
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
convertResponse (ReplApiResponse _ apiRslt batchCnt) =
  let ok = case _arResult apiRslt of
        Object h | HM.lookup (T.pack "status") h == Just "success" -> True
                 | HM.lookup (T.pack "tag") h == Just "ClusterChangeSuccess" -> True
                 | otherwise -> False
        _ -> False
  in Just TestResponse { resultSuccess = ok
                       , apiResult = apiRslt
                       , _batchCount = batchCnt }
convertResponse _ = Nothing  -- this shouldn't happen

_printResponses :: [ReplApiData] -> IO ()
_printResponses xs =
  forM_ xs printResponse where
    printResponse :: ReplApiData -> IO ()
    printResponse (ReplApiResponse _ apiRslt batchCnt) = do
      putStrLn $ "Batch count: " ++ show batchCnt
      putStrLn "\n***** printResponse *****"
      print $ _arResult apiRslt
      case _arMetaData apiRslt of
        Nothing -> putStrLn "(No meta data)"
        Just v -> putStrLn $ "Meta data: \n" ++ show v

    printResponse _ = return ()

isRequest :: ReplApiData -> Bool
isRequest (ReplApiRequest _ _) = True
isRequest ReplApiResponse{} = False

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

gatherMetrics :: [TestMetric] -> IO [TestMetricResult]
gatherMetrics tms = mapM (\tm -> do
    let name = metricNameTm tm
    value <- getMetric name
    return $ TestMetricResult { requestTmr = tm, valueTmr = value}) tms

getMetric :: String -> IO (Maybe String)
getMetric path = do
  let opts = defaults & header "Accept" .~ ["application/json"]
  rbs <- WR.getWith opts ("http://0.0.0.0:10080" ++ path)
  let str = C8.unpack $ rbs ^. responseBody
  let val = takeWhile (/= '}') $ takeWhileEnd (/= ':') str
  return $ Just val
