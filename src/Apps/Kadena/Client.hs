{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Apps.Kadena.Client
  ( main
  , calcInterval
  , CliCmd(..)
  , ClientConfig(..), ccSecretKey, ccPublicKey, ccEndpoints
  , ClientOpts(..), coptions, flushStrLn
  , esc
  , Formatter(..)
  , getClientEnv
  , getServer
  , handleCmd
  , initRequestId
  , Node(..)
  , parseCliCmd
  , Repl
  , replaceCounters
  , ReplApiData(..)
  , ReplConfig(..), rcClientConfig, rcClientEnv
  , ReplState(..)
  , runREPL
  , timeout
  ) where

import Control.Error.Util (hush)
import Control.Exception (IOException)
import Control.Monad.Extra hiding (loop)
import Control.Monad.Reader
import Control.Lens hiding (to,from)
import Control.Monad.Catch
import Control.Monad.Trans.RWS.Lazy as RWS
import Control.Concurrent.Lifted (threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.Async
import Control.Applicative

import qualified Data.Aeson as A
import Data.Aeson hiding ((.=), Result(..), Value(..))
import Data.Aeson.Encode.Pretty
import Data.Aeson.Lens
import Data.Aeson.Types hiding ((.=), Result(..))
import qualified Data.ByteString as B
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Default
import Data.Foldable
import Data.Function
import qualified Data.HashMap.Strict as HM
import Data.Int
import Data.List.Extra hiding (chunksOf)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import Data.Maybe
import qualified Data.Set as S
import Data.String
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Thyme.Clock
import Data.Thyme.Time.Core (unUTCTime, toMicroseconds)
import qualified Data.Vector as V
import qualified Data.Yaml as Y

import GHC.Generics (Generic)

import Network.HTTP.Client hiding (responseBody)

import Servant.Client.Core
import Servant.Client
import Servant.Server

import System.Console.GetOpt
import System.Environment
import System.Exit hiding (die)
import System.IO
import System.Time.Extra (sleep)

import Text.Trifecta as TF hiding (err, rendered, try)

import qualified Crypto.Ed25519.Pure as Ed25519

import qualified Pact.ApiReq as Pact
import qualified Pact.Types.API as Pact
import qualified Pact.Types.ChainMeta as Pact
import qualified Pact.Types.Command as Pact
import Pact.Types.Command ()
import qualified Pact.Types.Crypto as Pact
import qualified Pact.Types.Hash as Pact
import Pact.Types.RPC
import Pact.Types.Util

import Kadena.Command
import Kadena.ConfigChange (mkConfigChangeApiReq)
import Kadena.HTTP.ApiServer
import Kadena.Types.Base hiding (printLatTime)
import Kadena.Types.Command as K
import Kadena.Types.Entity (EntityName)
import qualified Kadena.Types.HTTP as K
import Kadena.Types.Private (PrivateResult)

#if ! MIN_VERSION_servant_server(0,16,0)
type ClientError = ServantError
#endif

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

listenDelayMs :: Int
listenDelayMs = 10000

data Node = Node
  { _nEntity :: EntityName
  , _nURL :: String
  , _nSender :: Bool
  } deriving (Eq,Generic,Ord)
instance ToJSON Node where toJSON = lensyToJSON 2
instance FromJSON Node where parseJSON = lensyParseJSON 2
instance Show Node where
  show Node{..} = _nURL ++ " [" ++ show _nEntity ++ ", sending: " ++ show _nSender ++ "]"

data ClientConfig = ClientConfig {
      _ccSecretKey :: Ed25519.PrivateKey
    , _ccPublicKey :: Ed25519.PublicKey
    , _ccEndpoints :: HM.HashMap String Node
    } deriving (Eq,Show,Generic)
makeLenses ''ClientConfig
instance ToJSON ClientConfig where toJSON = lensyToJSON 3
instance FromJSON ClientConfig where parseJSON = lensyParseJSON 3

data ReplConfig = ReplConfig
  { _rcClientConfig :: ClientConfig
  , _rcClientEnv :: ClientEnv
  }
makeLenses ''ReplConfig

data KeyPairFile = KeyPairFile {
    _kpKeyPairs :: [Pact.ApiKeyPair]
  } deriving (Generic)
instance FromJSON KeyPairFile where parseJSON = lensyParseJSON 3

data Mode = Transactional|Local
  deriving (Eq,Show,Ord,Enum)

data Formatter = YAML|Raw|PrettyJSON|Table deriving (Eq,Show)

data CliCmd =
  Batch Int |
  ParallelBatch
   { totalNumCmds :: Int
   , cmdRate :: Int
   , sleepBetweenBatches :: Int
   } |
  Cmd (Maybe String) |
  Data (Maybe String) |
  Exit |
  Format (Maybe Formatter) |
  Help |
  Keys (Maybe (T.Text,Maybe T.Text)) |
  LoadMultiple Int Int FilePath |
  LoadAsSingleTrans Int Int FilePath |
  Load FilePath Mode |
  ConfigChange FilePath |
  Poll String |
  PollMetrics String |
  Send Mode String |
  AsSingleTrans Int Int String |
  Multiple Int Int String |
  Private EntityName [EntityName] String |
  Server (Maybe String) |
  Sleep Int |
  Echo Bool
  deriving (Eq,Show)

data ReplState = ReplState {
      _server :: String
    , _batchCmd :: String
    , _requestId :: MVar Int64 -- this needs to be an MVar in case we get an exception mid function... it's our entropy
    , _cmdData :: Value
    , _keys :: [Pact.ApiKeyPair]
    , _fmt :: Formatter
    , _echo :: Bool
}
makeLenses ''ReplState

type Repl a = RWST ReplConfig [ReplApiData] ReplState IO a

data ReplApiData =
  ReplApiRequest
      { _apiRequestKey :: RequestKey
      , _replCmd :: String }
  | ReplApiResponse
      { _apiResponseKey ::  RequestKey
      , _apiResult :: CommandResult
      , _batchCnt :: Int64
} deriving Show

prompt :: String -> String
prompt s = "\ESC[0;31m" ++ s ++ "> \ESC[0m"

flushStr :: MonadIO m => String -> m ()
flushStr str = liftIO (putStr str >> hFlush stdout)

flushStrLn :: MonadIO m => String -> m ()
flushStrLn str = liftIO (putStrLn str >> hFlush stdout)

getServer :: ClientConfig -> ReplState -> String
getServer clientCfg replState =
  let ss = _ccEndpoints clientCfg
      s = _server replState
  in case HM.lookup s ss of
    Nothing -> die $ "Invalid server id: " ++ show s
    Just a -> (_nURL a)

readPrompt :: Repl (Maybe String)
readPrompt = do
  use server >>= flushStr . prompt
  e <- liftIO $ isEOF
  if e then return Nothing else Just <$> liftIO getLine

mkExec :: String -> Value -> Pact.PrivateMeta -> Repl (Pact.Command Text)
mkExec code mdata privMeta = do
  kps <- use keys
  rid <- use requestId >>= liftIO . (`modifyMVar` (\i -> return $ (succ i, i)))
  someKps <- liftIO $ Pact.mkKeyPairs kps
  cmd <- liftIO $ Pact.mkCommand
      someKps
      privMeta
      (T.pack $ show rid)
      Nothing
      (Exec (ExecMsg (T.pack code) mdata))
  return $ decodeUtf8 <$> cmd

handleHttpResp :: (t -> Repl ()) -> t -> Repl ()
handleHttpResp f r = f r

getClientEnv :: String -> IO ClientEnv
getClientEnv str = do
  url <- parseBaseUrl str
  manager' <- newManager defaultManagerSettings
  return $ mkClientEnv manager' url

----------------------------------------------------------------------------------------------------
-- Servant client endpoints
----------------------------------------------------------------------------------------------------
configChange :: ClientEnv -> SubmitCC -> IO Pact.RequestKeys
configChange env scc = do
  res <- runClientM (configChangeClient scc) env
  either dieBadRequest return res

send :: ClientEnv -> Pact.SubmitBatch -> IO Pact.RequestKeys
send env sb = do
  res <- runClientM (sendClient sb) env
  either dieBadRequest return res

sendLocal :: ClientEnv -> Pact.Command Text -> IO (Pact.CommandResult Pact.Hash)
sendLocal env cmd = do
  res <- runClientM (localClient cmd) env
  either dieBadRequest return res

sendPrivate :: ClientEnv -> (Pact.Command Text) -> IO Pact.RequestKeys
sendPrivate env cmd = do
  res <- runClientM (privateClient cmd) env
  either dieBadRequest return res

listenFor :: ClientEnv -> Pact.ListenerRequest -> IO K.CommandResult
listenFor env listenReq = do
  res <- runClientM (listenClient listenReq) env
  either dieBadRequest success res
  where
    success = \case
                Pact.ListenTimeout n -> dieListenTimeout n
                Pact.ListenResponse cr -> toKCmdResult cr

pollFor :: ClientEnv -> Pact.Poll -> IO K.PollResponses
pollFor env aPoll = do
  res <- runClientM (pollClient aPoll) env
  either dieBadRequest success res
  where
    success (Pact.PollResponses resMap) = do
      kResultMap <- traverse toKCmdResult resMap
      return $ K.PollResponses kResultMap

----------------------------------------------------------------------------------------------------
toKCmdResult :: Pact.CommandResult Hash -> IO K.CommandResult
toKCmdResult cr = do
  case Pact._crMetaData cr of
    Nothing -> dieBadRequestStr "Expected latency metadata in result"
    Just metaValue -> do
      case  fromJSON metaValue :: A.Result K.PactResultMeta of
        A.Error s -> dieBadRequestStr $ "Failure parsing metadata from result: " ++ s
        A.Success K.PactResultMeta{..} -> do
          return $ K.SmartContractResult
            { _scrPactResult = PactContractResult
              { _pcrHash = Pact.unRequestKey $ Pact._crReqKey cr
              , _pcrResult = cr
              , _pcrLogIndex = _prMetaLogIndex
              , _pcrLatMetrics = _prMetaLatMetrics
              }
            }

sendCmd :: Mode -> String -> String -> Repl ()
sendCmd m cmd replCmd = do
  j <- use cmdData
  c <- mkExec cmd j (Pact.PrivateMeta Nothing)
  -- Note: this is mkExec in this  module, not in Pact.ApiReq
  env <- view rcClientEnv
  case m of
    Transactional -> do
      resp <- liftIO $ send env $ Pact.SubmitBatch (c :| [])
      tellKeys resp replCmd
      handleHttpResp (listenForResult listenDelayMs) resp
    Local -> do
      res <- liftIO $ sendLocal env c
      -- output formatting via K.CommandResult, Pact's CommandResult represented by the
      -- SmartContractCommand constructor
      putJSONPactResult $ res

sendMultiple :: String -> String -> Int -> Int -> Repl ()
sendMultiple templateCmd replCmd startCount nRepeats  =
  sendMultiple' templateCmd replCmd startCount nRepeats False

-- | Similar to sendMultiple but with an extra Bool param which when True puts all the
--   transactions inside a single Cmd
sendMultiple' :: String -> String -> Int -> Int -> Bool -> Repl ()
sendMultiple' templateCmd replCmd startCount nRepeats singleCmd = do
  j <- use cmdData
  let cmds = replaceCounters startCount nRepeats templateCmd
  env <- view rcClientEnv
  cmds' <- sequence $
    if singleCmd then [mkExec (unwords cmds) j (Pact.PrivateMeta Nothing)]
    else fmap (\cmd -> mkExec cmd j (Pact.PrivateMeta Nothing)) cmds
  case NE.nonEmpty cmds' of
    Nothing -> flushStrLn $ "Apps.Kadena.Client.sendMultiple' - empty list of commands"
    Just ne -> do
      resp <- liftIO $ send env $ Pact.SubmitBatch ne
      tellKeys resp replCmd
      handleHttpResp (pollForResults True (Just nRepeats)) resp

loadMultiple :: FilePath -> String -> Int -> Int -> Repl ()
loadMultiple filePath replCmd startCount nRepeats =
  loadMultiple' filePath replCmd startCount nRepeats False

-- | Similar to sendMultiple but with an extra Bool param which when True puts all the
--   transactions inside a single Cmd
loadMultiple' :: FilePath -> String -> Int -> Int -> Bool -> Repl ()
loadMultiple' filePath replCmd startCount nRepeats singleCmd = do
  strOrErr <- liftIO $ try $ readFile filePath
  case strOrErr of
    Left (except :: IOException) -> liftIO $ die $ "Error reading template file " ++ show filePath
                                                 ++ "\n" ++ show except
    Right str -> do
      let xs = lines str
      let cmd = unwords xs -- carriage returns in the file now replaced with spaces
      sendMultiple' cmd replCmd startCount nRepeats singleCmd

sendConfigChangeCmd :: ConfigChangeApiReq -> String -> Repl ()
sendConfigChangeCmd ccApiReq@ConfigChangeApiReq{..} fileName = do
  execs <- liftIO $ mkConfigChangeExecs ccApiReq
  env <- view rcClientEnv
  let theJSONs = BSL.unpack $ encode (SubmitCC execs)
  -- TODO: remove after debugging is finished
  liftIO $ putStrLn $ "Client.sendConfigChangeCmd: \n" ++ theJSONs
  resp <- liftIO $ configChange env (SubmitCC execs)
  tellKeys resp fileName
  handleHttpResp (listenForLastResult listenDelayMs False) resp

tellKeys :: Pact.RequestKeys -> String -> Repl ()
tellKeys ks cmd = do
  tell $ fmap (\k -> ReplApiRequest { _apiRequestKey = k, _replCmd = cmd })
                     (NE.toList (Pact._rkRequestKeys ks))

sendPrivateCmd :: Pact.Address -> String -> Repl ()
sendPrivateCmd addy msg = do
  j <- use cmdData
  cmd <- mkExec msg j $ Pact.PrivateMeta (Just addy)
  env <- view rcClientEnv
  resp <- liftIO $ sendPrivate env cmd
  handleHttpResp (listenForResult listenDelayMs) resp

putJSONResult :: CommandResult -> Repl ()
putJSONResult SmartContractResult{..} = putJSONPactResult (_pcrResult _scrPactResult)
putJSONResult ConsensusChangeResult{..} = putJSON (_concrResult :: ClusterChangeResult)
putJSONResult PrivateCommandResult{..} = putJSON (_privResult :: PrivateResult (Pact.CommandResult Pact.Hash))

putJSONPactResult :: Pact.CommandResult Pact.Hash -> Repl ()
putJSONPactResult cr = putJSON (Pact._crResult cr :: Pact.PactResult)

putJSON :: (ToJSON a) => a -> Repl ()
putJSON a =
  use fmt >>= \f -> flushStrLn $ case f of
    Raw -> BSL.unpack $ encode a
    PrettyJSON -> BSL.unpack $ encodePretty a
    YAML -> doYaml
    Table -> fromMaybe doYaml $ pprintTable (toJSON a)
  where doYaml = BS8.unpack $ Y.encode a

batchTest :: Int -> String -> Repl ()
batchTest n cmd = do
  j <- use cmdData
  env <- view rcClientEnv
  flushStrLn $ "Preparing " ++ show n ++ " messages ..."
  cmdList <- replicateM n (mkExec cmd j (Pact.PrivateMeta Nothing))
  case NE.nonEmpty cmdList of
    Nothing -> flushStrLn $ "batchTest -- empty replicated list"
    Just neList ->  do
      resp <- liftIO $ send env (Pact.SubmitBatch neList)
      flushStrLn $ "Sent, retrieving responses"
      handleHttpResp (listenForLastResult listenDelayMs True) resp

chunksOf :: Int -> [e] -> [[e]]
chunksOf i ls = map (take i) (build (splitter ls)) where
  splitter :: [e] -> ([e] -> a -> a) -> a -> a
  splitter [] _ n = n
  splitter l c n  = l `c` splitter (drop i l) c n
  build :: ((a -> [a] -> [a]) -> [a] -> [a]) -> [a]
  build g = g (:) []

intoNumLists :: Int -> [e] -> [[e]]
intoNumLists numLists ls = chunksOf numPerList ls
  where
    numPerList :: Int
    numPerList = fromIntegral (ceiling
      ((fromIntegral $ length ls) / (fromIntegral numLists) :: Double) :: Integer)

processParBatchPerServer :: Int -> (MVar (), (Node, [[Pact.Command T.Text]])) -> IO ()
processParBatchPerServer sleep' (sema, (Node{..}, batches)) = do
  forM_ batches $ \batch -> do
    case NE.nonEmpty batch of
      Nothing -> flushStrLn $ "processParBatchPerServer -- empty batch"
      Just neBatch -> do
        clientEnv <- getClientEnv _nURL
        resp <- send clientEnv (Pact.SubmitBatch neBatch)
        flushStrLn $ "Sent a batch to " ++ _nURL
        rk <- return $ NE.last $ Pact._rkRequestKeys resp
        flushStrLn $ _nURL ++ " Success: " ++ show rk
        threadDelay (sleep' * 1000)
  liftIO $ putMVar sema ()

calcBatchSize :: Int -> Int -> Int -> Int
calcBatchSize cmdRate' sleep' clusterSize' = fromIntegral (ceiling $ cr * (sl/1000) / cs :: Int)
  where
    cr, sl, cs :: Double
    cr = fromIntegral cmdRate'
    sl = fromIntegral sleep'
    cs = fromIntegral clusterSize'

parallelBatchTest :: Int -> Int -> Int -> Repl ()
parallelBatchTest totalNumCmds' cmdRate' sleep' = do
  cmd <- use batchCmd
  j <- use cmdData
  rccc <- RWS.asks _rcClientConfig
  let eps  = _ccEndpoints rccc
  let servers = HM.elems eps

  batchSize' <- return $ calcBatchSize cmdRate' sleep' (length servers)
  semas <- replicateM (length servers) $ liftIO newEmptyMVar
  flushStrLn $ "Preparing " ++ show totalNumCmds' ++ " messages to distribute among "
    ++ show (length servers) ++ " servers in batches of " ++ show batchSize'
    ++ " with a delay of " ++ show sleep' ++ " milliseconds"
  allocatedBatches <- zip semas . zip servers . intoNumLists (length servers) . chunksOf batchSize'
    <$> replicateM totalNumCmds' (mkExec cmd j (Pact.PrivateMeta Nothing))
  liftIO $ forConcurrently_ allocatedBatches $ processParBatchPerServer sleep'
  liftIO $ forM_ semas takeMVar

load :: Mode -> FilePath -> Repl ()
load m fp = do
  --Note that MkApiReqExec calls mkExec defined in Pact.ApiReq, not the one defined in this module
  ((Pact.ApiReq {..},code,cdata,_),_) <- liftIO $ Pact.mkApiReq fp
  keys .= _ylKeyPairs
  cmdData .= cdata
  sendCmd m code fp
  -- re-parse yaml for batch command
  v :: Value <- either (\pe -> die $ "File load failed: " ++ show pe) return =<<
                liftIO (Y.decodeFileEither fp)
  case firstOf (key "batchCmd" . _String) v of
    Nothing -> return ()
    Just c -> flushStrLn ("Setting batch command to: " ++ show c) >> batchCmd .= (T.unpack c)
  cmdData .= Null

loadConfigChange :: FilePath -> Repl ()
loadConfigChange fp = do
  ccApiReq <- liftIO $ mkConfigChangeApiReq fp
  sendConfigChangeCmd ccApiReq fp

listenForResult :: Int -> Pact.RequestKeys -> Repl ()
listenForResult tdelay theKeys = do
  let (_ :| xs) = Pact._rkRequestKeys theKeys
  unless (null xs) $ do
    flushStrLn "Expecting one result but found many"
  listenForLastResult tdelay False theKeys

listenForLastResult :: Int -> Bool -> Pact.RequestKeys -> Repl ()
listenForLastResult tdelay showLatency theKeys = do
  let rks = Pact._rkRequestKeys theKeys
  let cnt = fromIntegral $ length rks
  threadDelay tdelay
  let lastRk = NE.last rks
  env <- view rcClientEnv
  result <- liftIO $ listenFor env $ Pact.ListenerRequest lastRk
  tell [ReplApiResponse { _apiResponseKey = lastRk
                        , _apiResult = result
                        , _batchCnt = fromIntegral cnt}]
  if showLatency then do
    let latMetrics = case result of
          SmartContractResult pactCr -> _pcrLatMetrics pactCr
          nonPactCr -> _crLatMetrics nonPactCr
    case latMetrics of
      Nothing -> flushStrLn "Success"
      Just lats@CmdResultLatencyMetrics{..} -> do
        pprintLatency lats
        case _rlmFinExecution of
          Nothing -> flushStrLn "Latency Measurement Unavailable"
          Just n -> flushStrLn $ intervalOfNumerous cnt n
  else putJSONResult result

pollMaxRetry :: Int
pollMaxRetry = 180

-- | pollForResults' Maybe param holds the true number of 'commands' processed.
--   This is needed when commands are combined into a single Pact transaction.
pollForResults :: Bool -> (Maybe Int) -> Pact.RequestKeys -> Repl ()
pollForResults showLatency mTrueCount theKeys = do
  let rks = Pact._rkRequestKeys theKeys
  when (null rks) $ do
    flushStrLn "pollForResults -- called with an empty list of request keys"
    return ()
  let keyCount = length rks
  go rks keyCount pollMaxRetry

  where
    go :: NonEmpty RequestKey -> Int -> Int -> Repl ()
    go _rks _keyCount 0 = do
      flushStrLn "Timeout on pollForResults -- not all results were received"
      return ()
    go rks keyCount retryCount = do
      env <- view rcClientEnv
      resp <- liftIO $ pollFor env $ Pact.Poll rks
      let (K.PollResponses responseMap)  = resp
      let ks = HM.keys responseMap :: [RequestKey]
      if length ks < keyCount
      then do
        liftIO $ sleep 1
        go rks keyCount (retryCount - 1)
      else do
        flushStrLn $ "\nReceived all the keys: (" ++ show (length ks) ++ " of "
                  ++ show keyCount ++ " on try #" ++ show ( pollMaxRetry- retryCount + 1) ++ ")"
        (allOk, theResults) <-  liftIO $ foldM (checkEach responseMap) (True, []) ks
        when allOk $ do
          liftIO $ putStrLn "All commands successful"
        when (showLatency && not (null theResults)) $ do
          let numTrueTrans = fromMaybe keyCount mTrueCount
          printLatencyMetrics (last theResults) $ fromIntegral numTrueTrans
          return ()

checkEach :: (HM.HashMap RequestKey CommandResult)
          -> (Bool, [CommandResult]) -> RequestKey -> IO (Bool, [CommandResult])
checkEach responseMap (b, xs) theKey = do
  case HM.lookup theKey responseMap of
    Nothing -> do
      putStrLn "Request key missing from the response map"
      return (False, xs)
    Just cmdResult  -> return (b, cmdResult : xs)

printLatencyMetrics :: CommandResult -> Int64 -> Repl ()
printLatencyMetrics result cnt = do
  case _crLatMetrics result of
    Nothing -> flushStrLn "Metrics Unavailable"
    Just metrics -> do
      pprintLatency metrics
      case _rlmFinExecution metrics of
        Nothing -> flushStrLn "Latency Measurement Unavailable"
        Just n -> flushStrLn $ intervalOfNumerous cnt n

handlePollCmds :: Bool -> RequestKey -> Repl ()
handlePollCmds printMetrics rk = do
  env <- view rcClientEnv
  resp <- liftIO $ pollFor env $ Pact.Poll (rk :| [])

  let (K.PollResponses prs) = resp
  tell (fmap (\(k, v) -> ReplApiResponse
          { _apiResponseKey = k
          , _apiResult = v
          , _batchCnt = 1 }) (HM.toList prs))
  forM_ (HM.elems prs) $ \cmdResult -> do
    putJSON cmdResult
    when printMetrics $
      case _crLatMetrics cmdResult of
        Nothing -> flushStrLn "Metrics Unavailable"
        Just (lats@CmdResultLatencyMetrics{..}) -> pprintLatency lats

printLatTime :: (Num a, Ord a, Show a) => a -> String
printLatTime s
  | s >= 1000000 =
      let s' = drop 4 $ reverse $ show s
          s'' = reverse $ (take 2 s') ++ "." ++ (drop 2 s')
      in s'' ++ " second(s)"
  | s >= 1000 =
      let s' = drop 1 $ reverse $ show s
          s'' = reverse $ (take 2 s') ++ "." ++ (drop 2 s')
          s''' = if length s'' == 5 then " " ++ s'' else s''
      in s''' ++ " milli(s)"
  | length (show s) == 1 = "  " ++ show s ++ " micro(s)"
  | length (show s) == 2 = " " ++ show s ++ " micro(s)"
  | otherwise = show s ++ " micro(s)"

getLatDelta :: (Num a, Ord a, Show a) => Maybe a -> Maybe a -> Maybe a
getLatDelta (Just st) (Just ed) = Just $ ed - st
getLatDelta _ _ = Nothing

pprintLatency :: CmdResultLatencyMetrics -> Repl ()
pprintLatency CmdResultLatencyMetrics{..} = do
  let mFlushStr s1 v = case v of
        Nothing -> return ()
        Just v' -> flushStrLn $ s1 ++ printLatTime v'
  flushStrLn $ "First Seen:          " ++ (show _rlmFirstSeen)
  mFlushStr "Hit Turbine:        +" _rlmHitTurbine
  mFlushStr "Entered Con Serv:   +" _rlmHitConsensus
  mFlushStr "Finished Con Serv:  +" _rlmFinConsensus
  mFlushStr "Came to Consensus:  +" _rlmAerConsensus
  mFlushStr "Sent to Execution:  +" _rlmLogConsensus
  mFlushStr "Started PreProc:    +" _rlmHitPreProc
  mFlushStr "Finished PreProc:   +" _rlmFinPreProc
  mFlushStr "Crypto took:         " (getLatDelta _rlmHitPreProc _rlmFinPreProc)
  mFlushStr "Started Execution:  +" _rlmHitExecution
  mFlushStr "Finished Execution: +" _rlmFinExecution
  mFlushStr "Pact exec took:      " (getLatDelta _rlmHitExecution _rlmFinExecution)

pprintTable :: Value -> Maybe String
pprintTable val = do
  os <- firstOf (key "data" . _Array) val >>= traverse (firstOf _Object)
  let rendered = fmap (fmap (BSL.unpack . encode)) os
  let lengths = foldl' f HM.empty rendered
        where
          f r m = HM.unionWith max (HM.mapWithKey (\k v -> max (T.length k) (length v)) m) r
  let fill n s = s ++ replicate (n - length s) ' '
  let keyLengths = sortBy (compare `on` fst) $ HM.toList lengths
  let colify m = intercalate " | " $ (`map` keyLengths) $ \(k,l) -> fill l $ fromMaybe "" $ HM.lookup k m
  let h1 = colify (HM.mapWithKey (\k _ -> T.unpack k) lengths)
  return $ h1 ++ "\n" ++ (replicate (length h1) '-')
              ++ "\n" ++ intercalate "\n" (V.toList $ fmap colify rendered)

parseMode :: TF.Parser Mode
parseMode =
  (symbol "tx" >> pure Transactional) <|>
  (symbol "transactional" >> pure Transactional) <|>
  (symbol "local" >> pure Local)

cliCmds :: [(String,String,String,TF.Parser CliCmd)]
cliCmds =
  [ ("sleep","[MILLIS]","Pause for 5 sec or MILLIS",
      Sleep . fromIntegral . fromMaybe 5000 <$> optional integer)
  , ("cmd","[COMMAND]","Show/set current batch command",
      Cmd <$> optional (some anyChar))
  , ("data","[JSON]","Show/set current JSON data payload",
      Data <$> optional (some anyChar))
  , ("echo", "on|off", "Set message echoing on|off",
       Echo <$> ((symbol "on" >> pure True) <|> (symbol "off" >> pure False)))
  , ("loadMultiple", "START_COUNT REPEAT_TIMES TEMPLATE_TEXT_FILE",
     "Batch multiple commands togehter and send transactionally to the server",
     LoadMultiple <$> (fromIntegral <$> integer) <*> (fromIntegral <$> integer) <*> some anyChar)
  , ("loadAsSingleTrans", "START_COUNT REPEAT_TIMES TEMPLATE_TEXT_FILE",
     "Batch multiple commands togehter and send to the server as a single Pact "
     ++ "command / transaction",
     LoadAsSingleTrans <$> (fromIntegral <$> integer) <*> (fromIntegral <$> integer) <*> some anyChar)
  , ("load","YAMLFILE [MODE]",
     "Load and submit yaml file with optional mode (transactional|local), defaults to transactional",
      Load <$> some anyChar <*> (fromMaybe Transactional <$> optional parseMode))
  , ("batch","TIMES","Repeat command in batch message specified times",
     Batch . fromIntegral <$> integer)
  , ("par-batch","TOTAL_CMD_CNT CMD_PER_SEC SLEEP"
        , "Similar to `batch` but the commands are distributed among the nodes:\n"
       ++ "  * the REPL will create N batch messages and group them into individual batches\n"
       ++ "  * CMD_PER_SEC refers to the overall command submission rate\n"
       ++ "  * individual batch sizes are calculated by `ceiling (CMD_PER_SEC * (SLEEP/1000) / clusterSize)`\n"
       ++ "  * submit them (in parallel) to each available node\n"
       ++ "  * pause for S milliseconds between submissions to a given server",
   ParallelBatch <$> (fromIntegral <$> integer)
                 <*> (fromIntegral <$> integer)
                 <*> (fromIntegral <$> integer))
  , ("pollMetrics","REQUESTKEY",
     "Poll each server for the request key but print latency metrics from each.",
     PollMetrics <$> some anyChar)
  , ("poll","REQUESTKEY", "Poll server for request key",
     Poll <$> some anyChar)
  , ("exec","COMMAND","Send command transactionally to server",
     Send Transactional <$> some anyChar)
  , ("local","COMMAND","Send command locally to server",
     Send Local <$> some anyChar)
  , ("server","[SERVERID]","Show server info or set current server",
     Server <$> optional (some anyChar))
  , ("help","","Show command help", pure Help)
  , ("keys","[PUBLIC PRIVATE | FILE]","Show or set signing keypair/read keypairs from file",
     Keys <$> optional ((,) <$> (T.pack <$> some anyChar) <*>
             (optional (spaces >> (T.pack <$> some alphaNum)))))
  , ("exit","","Exit client", pure Exit)
  , ("format","[FORMATTER]","Show/set current output formatter (yaml|raw|pretty|table)",
     Format <$> optional ((symbol "yaml" >> pure YAML) <|>
                          (symbol "raw" >> pure Raw) <|>
                          (symbol "pretty" >> pure PrettyJSON) <|>
                          (symbol "table" >> pure Table)))
  , ("private","TO [FROM1 FROM2...] CMD",
     "Send private transactional command to server addressed with entity names", parsePrivate)
  , ("configChange", "YAMLFILE", "Load and submit transactionally a yaml configuration change file",
     ConfigChange <$> some anyChar)
  , ("multiple", "START_COUNT REPEAT_TIMES COMMAND",
     "Batch multiple commands togehter and send transactionally to the server",
     Multiple <$> (fromIntegral <$> integer) <*> (fromIntegral <$> integer) <*> some anyChar)
  , ("asSingleTransaction", "START_COUNT REPEAT_TIMES COMMAND",
     "Batch multiple commands togehter and send to the server as a single Pact Cmd/Transaction",
     AsSingleTrans <$> (fromIntegral <$> integer) <*> (fromIntegral <$> integer) <*> some anyChar)
  ]

parsePrivate :: TF.Parser CliCmd
parsePrivate = do
  to <- fromString <$> some alphaNum
  spaces
  from <- map fromString <$> brackets (sepBy (some alphaNum) (some space))
  spaces
  cmd <- some anyChar
  return $ Private to from cmd

parseCliCmd :: TF.Parser CliCmd
parseCliCmd = foldl1 (<|>) (map (\(c,_,_,p) -> symbol c >> p) cliCmds)

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
        Just cmd -> case parseString parseCliCmd mempty cmd of
          Failure (ErrInfo e _) -> do
            flushStrLn $ "Parse failure (help for command help):\n" ++ show e
            loop True
          Success c -> case c of
            Exit -> loop False
            _ -> handleCmd c cmd >> loop True

handleCmd :: CliCmd -> String -> Repl ()
handleCmd cmd reqStr = case cmd of
  Help -> help
  Sleep i -> threadDelay (i * 1000)
  Cmd Nothing -> use batchCmd >>= flushStrLn
  Cmd (Just c) -> batchCmd .= c
  Send m c -> sendCmd m c reqStr
  Multiple m n c -> sendMultiple c reqStr m n
  AsSingleTrans m n c -> sendMultiple' c reqStr m n True
  LoadMultiple m n fp -> loadMultiple fp reqStr m n
  LoadAsSingleTrans m n fp -> loadMultiple' fp reqStr m n True
  Server Nothing -> do
    use server >>= \s -> flushStrLn $ "Current server: " ++ s
    flushStrLn "Servers:"
    rccc <- RWS.asks _rcClientConfig
    let ep  = _ccEndpoints rccc
    forM_ (sort $ HM.toList ep) $ \(i,e) ->
      flushStrLn $ i ++ ": " ++ show e

  Server (Just s) -> server .= s
  Batch n | n <= 50000 -> use batchCmd >>= batchTest n
          | otherwise -> void $ flushStrLn "Aborting: batch count limited to 50000"
  ParallelBatch{..}
    | cmdRate >= 20000 -> void $ flushStrLn "Aborting: cmd rate too large (limited to 25k/s)"
    | sleepBetweenBatches < 250 -> void $ flushStrLn "Aborting: sleep between batches needs to be >= 250"
    | otherwise -> parallelBatchTest totalNumCmds cmdRate sleepBetweenBatches
  Load s m -> load m s
  ConfigChange fp -> loadConfigChange fp
  Poll s -> parseRK s >>= void . handlePollCmds False . RequestKey . Hash
  PollMetrics rk -> do
    s <- use server
    rccc <- RWS.asks _rcClientConfig
    let ep  = _ccEndpoints rccc
    let sList = HM.toList ep
    rk' <- parseRK rk
    forM_ sList $ \(s',_) -> do
      server .= s'
      flushStrLn $ "##############  " ++ s' ++ "  ##############"
      void $ handlePollCmds True $ RequestKey $ Hash rk'
    server .= s
  Exit -> return ()
  Data Nothing -> use cmdData >>= flushStrLn . BSL.unpack . encode
  Data (Just s) -> either (\e -> flushStrLn $ "Bad JSON value: " ++ show e) (cmdData .=) $ eitherDecode (BSL.pack s)
  Keys Nothing -> use keys >>= mapM_ putJSON
  Keys (Just (p,Just s)) -> do
    sk <- case fromJSON (String s) of
      A.Error e -> die $ "Bad secret key value: " ++ show e
      A.Success k -> return k
    pk <- case fromJSON (String p) of
      A.Error e -> die $ "Bad public key value: " ++ show e
      A.Success k -> return k
    keys .= [Pact.ApiKeyPair sk pk Nothing Nothing Nothing]
  Keys (Just (kpFile,Nothing)) -> do
    (KeyPairFile kps) <- either (die . show) return =<< liftIO (Y.decodeFileEither (T.unpack kpFile))
    keys .= kps
  Format Nothing -> use fmt >>= flushStrLn . show
  Format (Just f) -> fmt .= f
  Private to from msg -> sendPrivateCmd (Pact.Address to (S.fromList from)) msg
  Echo e -> echo .= e

parseRK :: String -> Repl B.ByteString
parseRK cmd = case B16.decode $ BS8.pack cmd of
  (rk,leftovers)
    | B.empty /= leftovers ->
     die $ "Failed to decode RequestKey: this was converted " ++
      show rk ++ " and this was not " ++ show leftovers
    | otherwise -> return rk

help :: Repl ()
help = do
  flushStrLn "Command Help:"
  forM_ cliCmds $ \(cmd,args,docs,_) -> do
    flushStrLn $ cmd ++ " " ++ args
    flushStrLn $ "    " ++ docs

intervalOfNumerous :: Int64 -> Int64 -> String
intervalOfNumerous cnt mics = let
  (interval', perSec) = calcInterval cnt mics
  in "Completed in " ++ show (interval' :: Double) ++
     "sec (" ++ show perSec ++ " per sec)"

calcInterval :: Int64 -> Int64 -> (Double, Integer)
calcInterval cnt mics =
  let interval' = fromIntegral mics / 1000000
      perSec = ceiling (fromIntegral cnt / interval')
  in (interval', perSec)

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
      (conf :: ClientConfig) <- either (\e -> print e >> exitFailure) return =<<
        Y.decodeFileEither (_oConfig opts)
      let replState = ReplState
            { _server = fst (minimum $ HM.toList (_ccEndpoints conf))
            , _batchCmd = "\"Hello Kadena\""
            , _requestId = i
            , _cmdData = Null
            , _keys = [ Pact.ApiKeyPair
                        { _akpSecret = Pact.PrivBS (Ed25519.exportPrivate (_ccSecretKey conf))
                        , _akpPublic = Just (Pact.PubBS (Ed25519.exportPublic (_ccPublicKey conf)))
                        , _akpAddress = Nothing
                        , _akpScheme =  Nothing
                        , _akpCaps = Nothing } ]
            , _fmt = Table
            , _echo = False
            }
      let theServer = getServer conf replState
      clientEnv <- getClientEnv theServer
      let replConfig = ReplConfig
            { _rcClientConfig = conf
            , _rcClientEnv = clientEnv
            }
      _ <- runRWST runREPL replConfig replState
      return ()

esc :: String -> String
esc s = "\"" ++ s ++ "\""

-- | replaces occurrances of ${count} with the specied number
replaceCounters :: Int -> Int -> String -> [String]
replaceCounters start nRepeats cmdTemplate =
  let counts = [start, start+1..(start + nRepeats - 1)]
      commands = foldr f [] counts where
        f :: Int -> [String] -> [String]
        f x r = replaceCounter x cmdTemplate : r
  in commands

replaceCounter :: Int -> String -> String
replaceCounter n s = replace "${count}" (show n) s

timeout :: Int -> IO a -> IO (Maybe a)
timeout n io = hush <$> race (threadDelay $ n * 1000000) io

die :: MonadThrow m => String -> m a
die = throwM . userError


dieBadRequest :: ClientError -> IO a
dieBadRequest err = dieBadRequestStr $ show err

dieBadRequestStr :: String -> IO a
dieBadRequestStr str = do
  putStrLn $ "Error: " ++ str
  throwM err400 { errBody = BSL.pack str }

dieListenTimeout :: Int -> IO a
dieListenTimeout n = do
  let s = "Error - listen request timeout (" ++ show n ++ ")"
  putStrLn s
  throwM err400 { errBody = BSL.pack s }
