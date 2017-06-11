{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}

module Apps.Kadena.Client
  ( main
  , ClientConfig(..), ccSecretKey, ccPublicKey, ccEndpoints
  , Node(..)
  ) where

import qualified Control.Exception as Exception
import Control.Monad.State
import Control.Monad.Reader
import Control.Lens hiding (to,from)
import Control.Monad.Catch
import Control.Concurrent.Lifted (threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.Async
import Control.Applicative

import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.HashMap.Strict as HM
import qualified Data.Vector as V
import qualified Data.Set as S
import Data.Function

import qualified Data.Aeson as A
import Data.Aeson hiding ((.=), Result(..), Value(..))
import Data.Aeson.Lens
import Data.Aeson.Types hiding ((.=),parse, Result(..))
import Data.Aeson.Encode.Pretty
import qualified Data.Yaml as Y

import Text.Trifecta as TF hiding (err,render,rendered)

import Data.Default
import Data.Foldable
import Data.Int
import Data.Maybe
import Data.List
import Data.String
import Data.Thyme.Clock
import Data.Thyme.Time.Core (unUTCTime, toMicroseconds)
import GHC.Generics (Generic)
import Network.Wreq hiding (Raw)
import System.Console.GetOpt
import System.Environment
import System.Exit hiding (die)
import System.IO
import System.Directory
import System.FilePath

import Pact.Types.API hiding (Poll)
import qualified Pact.Types.API as Pact
import Pact.Types.RPC
import qualified Pact.Types.Command as Pact
import qualified Pact.Types.Crypto as Pact
import Pact.Types.Util


import Kadena.Types.Base hiding (printLatTime)
import Kadena.Types.Entity (EntityName)
import Kadena.Types.Command (CmdResultLatencyMetrics(..))

data KeyPair = KeyPair {
  _kpSecret :: PrivateKey,
  _kpPublic :: PublicKey
  } deriving (Eq,Show,Generic)
instance ToJSON KeyPair where toJSON = lensyToJSON 3
instance FromJSON KeyPair where parseJSON = lensyParseJSON 3

data YamlLoad = YamlLoad {
  _ylData :: Maybe String,
  _ylDataFile :: Maybe FilePath,
  _ylCode :: Maybe String,
  _ylCodeFile :: Maybe FilePath,
  _ylKeyPairs :: [KeyPair],
  _ylBatchCmd :: Maybe String
  } deriving (Eq,Show,Generic)
instance ToJSON YamlLoad where toJSON = lensyToJSON 3
instance FromJSON YamlLoad where parseJSON = lensyParseJSON 3

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
      _ccSecretKey :: PrivateKey
    , _ccPublicKey :: PublicKey
    , _ccEndpoints :: HM.HashMap String Node
    } deriving (Eq,Show,Generic)
makeLenses ''ClientConfig
instance ToJSON ClientConfig where toJSON = lensyToJSON 3
instance FromJSON ClientConfig where parseJSON = lensyParseJSON 3


data Mode = Transactional|Local
  deriving (Eq,Show,Ord,Enum)

data Formatter = YAML|Raw|PrettyJSON|Table deriving (Eq,Show)

data CliCmd =
  Batch Int |
  ParallelBatch
   { totalNumCmds :: Int
   , batchSize :: Int
   , sleepBetweenBatches :: Int
   } |
  Cmd (Maybe String) |
  Data (Maybe String) |
  Exit |
  Format (Maybe Formatter) |
  Help |
  Keys (Maybe (T.Text,T.Text)) |
  Load FilePath Mode |
  Poll String |
  PollMetrics String |
  Send Mode String |
  Private EntityName [EntityName] String |
  Server (Maybe String) |
  Sleep Int
  deriving (Eq,Show)

data ReplState = ReplState {
      _server :: String
    , _batchCmd :: String
    , _requestId :: MVar Int64 -- this needs to be an MVar in case we get an exception mid function... it's our entropy
    , _cmdData :: Value
    , _keys :: [KeyPair]
    , _fmt :: Formatter
}
makeLenses ''ReplState

type Repl a = ReaderT ClientConfig (StateT ReplState IO) a

prompt :: String -> String
prompt s = "\ESC[0;31m" ++ s ++ "> \ESC[0m"

die :: MonadThrow m => String -> m a
die = throwM . userError

flushStr :: MonadIO m => String -> m ()
flushStr str = liftIO (putStr str >> hFlush stdout)

flushStrLn :: MonadIO m => String -> m ()
flushStrLn str = liftIO (putStrLn str >> hFlush stdout)

getServer :: Repl String
getServer = do
  ss <- view ccEndpoints
  s <- use server
  case HM.lookup s ss of
    Nothing -> die $ "Invalid server id: " ++ show s
    Just a -> return (_nURL a)

readPrompt :: Repl (Maybe String)
readPrompt = do
  use server >>= flushStr . prompt
  e <- liftIO $ isEOF
  if e then return Nothing else Just <$> liftIO getLine

mkExec :: String -> Value -> Maybe Pact.Address -> Repl (Pact.Command T.Text)
mkExec code mdata addy = do
  kps <- use keys
  rid <- use requestId >>= liftIO . (`modifyMVar` (\i -> return $ (succ i, i)))
  return $ decodeUtf8 <$>
    Pact.mkCommand
    (map (\KeyPair {..} -> (Pact.ED25519,_kpSecret,_kpPublic)) kps)
    addy
    (T.pack $ show rid)
    (Exec (ExecMsg (T.pack code) mdata))

postAPI :: (ToJSON req,FromJSON resp) => String -> req -> Repl (Response resp)
postAPI ep rq = do
  s <- getServer
  liftIO $ postSpecifyServerAPI ep s rq

postSpecifyServerAPI :: (ToJSON req,FromJSON resp) => String -> String -> req -> IO (Response resp)
postSpecifyServerAPI ep server' rq = do
  r <- liftIO $ post ("http://" ++ server' ++ "/api/v1/" ++ ep) (toJSON rq)
  asJSON r

handleResp :: (t -> Repl ()) -> Response (ApiResponse t) -> Repl ()
handleResp a r = do
        case r ^. responseBody of
          ApiFailure{..} -> flushStrLn $ "Failure in API Send: " ++ show _apiError
          ApiSuccess{..} -> a _apiResponse

handleBatchResp :: RequestKeys -> Repl ()
handleBatchResp resp = do
        rk <- return $ head $ _rkRequestKeys resp
        showResult 10000 [rk] Nothing

sendCmd :: Mode -> String -> Repl ()
sendCmd m cmd = do
  j <- use cmdData
  e <- mkExec cmd j Nothing
  case m of
    Transactional -> postAPI "send" (SubmitBatch [e]) >>= handleResp handleBatchResp
    Local -> postAPI "local" e >>=
             handleResp (\(resp :: Value) -> putJSON resp)

sendPrivate :: Pact.Address -> String -> Repl ()
sendPrivate addy msg = do
  j <- use cmdData
  e <- mkExec msg j (Just addy)
  postAPI "private" (SubmitBatch [e]) >>= handleResp handleBatchResp


putJSON :: ToJSON a => a -> Repl ()
putJSON a = use fmt >>= \f -> flushStrLn $ case f of
  Raw -> BSL.unpack $ encode a
  PrettyJSON -> BSL.unpack $ encodePretty a
  YAML -> doYaml
  Table -> fromMaybe doYaml $ pprintTable (toJSON a)
  where doYaml = BS8.unpack $ Y.encode a


batchTest :: Int -> String -> Repl ()
batchTest n cmd = do
  j <- use cmdData
  flushStrLn $ "Preparing " ++ show n ++ " messages ..."
  es <- SubmitBatch <$> replicateM n (mkExec cmd j Nothing)
  resp <- postAPI "send" es
  flushStrLn $ "Sent, retrieving responses"
  case resp ^. responseBody of
    ApiFailure{..} -> do
      flushStrLn $ "Failure: " ++ show _apiError
    ApiSuccess{..} -> do
      rk <- return $ last $ _rkRequestKeys _apiResponse
      flushStrLn $ "Polling for RequestKey: " ++ show rk
      showResult 10000 [rk] (Just (fromIntegral n))

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
    numPerList = fromIntegral (ceiling ((fromIntegral $ length ls) / (fromIntegral numLists) :: Double) :: Integer)

processParBatchPerServer :: Int -> (MVar (), (Node, [[Pact.Command T.Text]])) -> IO ()
processParBatchPerServer sleep' (sema, (Node{..}, batches)) = do
  forM_ batches $ \batch -> do
    resp <- postSpecifyServerAPI "send" _nURL $ SubmitBatch batch
    flushStrLn $ "Sent a batch to " ++ _nURL
    case resp ^. responseBody of
      ApiFailure{..} -> do
        flushStrLn $ _nURL ++ " Failure: " ++ show _apiError
      ApiSuccess{..} -> do
        rk <- return $ last $ _rkRequestKeys _apiResponse
        flushStrLn $ _nURL ++ " Success: " ++ show rk
    threadDelay (sleep' * 1000)
  putMVar sema ()

parallelBatchTest :: Int -> Int -> Int -> Repl ()
parallelBatchTest totalNumCmds' batchSize' sleep' = do
  cmd <- use batchCmd
  j <- use cmdData
  servers <- HM.elems <$> view ccEndpoints
  semas <- replicateM (length servers) $ liftIO newEmptyMVar
  flushStrLn $ "Preparing " ++ show totalNumCmds' ++ " messages to distribute among "
    ++ show (length servers) ++ " servers in batches of " ++ show batchSize'
    ++ " with a delay of " ++ show sleep' ++ " milliseconds"
  allocatedBatches <- zip semas . zip servers . intoNumLists (length servers) . chunksOf batchSize' <$> replicateM totalNumCmds' (mkExec cmd j Nothing)
  liftIO $ forConcurrently_ allocatedBatches $ processParBatchPerServer sleep'
  liftIO $ forM_ semas takeMVar

load :: Mode -> FilePath -> Repl ()
load m fp = do
  YamlLoad {..} <- either (\pe -> die $ "File load failed: " ++ show pe) return =<<
        liftIO (Y.decodeFileEither fp)
  oldCwd <- liftIO $ getCurrentDirectory
  liftIO $ setCurrentDirectory (takeDirectory fp)
  (code,cdata) <- (`finally` liftIO (setCurrentDirectory oldCwd)) $ do
    code <- case (_ylCodeFile,_ylCode) of
      (Nothing,Just c) -> return c
      (Just f,Nothing) -> liftIO (readFile f)
      _ -> die "Expected either a 'code' or 'codeFile' entry"
    cdata <- case (_ylDataFile,_ylData) of
      (Nothing,Just v) -> either (\e -> die $ "Data decode failed: " ++ show e) return $ eitherDecode (BSL.pack v)
      (Just f,Nothing) -> liftIO (BSL.readFile f) >>=
                          either (\e -> die $ "Data file load failed: " ++ show e) return .
                          eitherDecode
      (Nothing,Nothing) -> return Null
      _ -> die "Expected either a 'data' or 'dataFile' entry, or neither"
    return (code,cdata)
  keys .= _ylKeyPairs
  cmdData .= cdata
  sendCmd m code
  case _ylBatchCmd of
    Nothing -> return ()
    Just c -> flushStrLn ("Setting batch command to: " ++ c) >> batchCmd .= c
  cmdData .= Null

showResult :: Int -> [RequestKey] -> Maybe Int64 -> Repl ()
showResult _ [] _ = return ()
showResult tdelay rks countm = loop (0 :: Int)
  where
    loop c = do
      threadDelay tdelay
      when (c > 100) $ flushStrLn "Timeout"
      resp <- postAPI "listen" (ListenerRequest $ last rks)
      case resp ^. responseBody of
        ApiFailure err -> flushStrLn $ "Error: no results received: " ++ show err
        ApiSuccess ApiResult{..} ->
                case countm of
                  Nothing -> putJSON _arResult
                  Just cnt -> case fromJSON <$>_arMetaData of
                    Nothing -> flushStrLn "Success"
                    Just (A.Success lats@CmdResultLatencyMetrics{..}) -> do
                      pprintLatency lats
                      case _rlmFinCommit of
                        Nothing -> flushStrLn "Latency Measurement Unavailable"
                        Just n -> flushStrLn $ intervalOfNumerous cnt n
                    Just (A.Error err) -> flushStrLn $ "metadata decode failure: " ++ err

pollForResult :: Bool -> RequestKey -> Repl ()
pollForResult printMetrics rk = do
  s <- getServer
  eR <- liftIO $ Exception.try $ post ("http://" ++ s ++ "/api/v1/poll") (toJSON (Pact.Poll [rk]))
  case eR of
    Left (SomeException err) -> flushStrLn $ show err
    Right r -> do
      resp <- asJSON r
      case resp ^. responseBody of
        ApiFailure err -> flushStrLn $ "Error: no results received: " ++ show err
        ApiSuccess (PollResponses prs) -> forM_ (HM.elems prs) $ \ApiResult{..} -> do
          putJSON _arResult
          when printMetrics $ do
                case fromJSON <$>_arMetaData of
                  Nothing -> flushStrLn "Metrics Unavailable"
                  Just (A.Success lats@CmdResultLatencyMetrics{..}) -> do
                    pprintLatency lats
                  Just (A.Error err) -> flushStrLn $ "metadata decode failure: " ++ err


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
  mFlushStr "Sent to Commit:     +" _rlmLogConsensus
  mFlushStr "Started PreProc:    +" _rlmHitPreProc
  mFlushStr "Finished PreProc:   +" _rlmFinPreProc
  mFlushStr "Crypto took:         " (getLatDelta _rlmHitPreProc _rlmFinPreProc)
  mFlushStr "Started Commit:     +" _rlmHitCommit
  mFlushStr "Finished Commit:    +" _rlmFinCommit
  mFlushStr "Pact exec took:      " (getLatDelta _rlmHitCommit _rlmFinCommit)

pprintTable :: Value -> Maybe String
pprintTable val = do
  os <- firstOf (key "data" . _Array) val >>= sequence . fmap (firstOf _Object)
  let rendered = fmap (fmap (BSL.unpack . encode)) os
      lengths = foldl' (\r m -> HM.unionWith max (HM.mapWithKey (\k v -> max (T.length k) (length v)) m) r) HM.empty rendered
      fill n s = s ++ replicate (n - length s) ' '
      keyLengths = sortBy (compare `on` fst) $ HM.toList lengths
      colify m = intercalate " | " $ (`map` keyLengths) $ \(k,l) -> fill l $ fromMaybe "" $ HM.lookup k m
      h1 = colify (HM.mapWithKey (\k _ -> T.unpack k) lengths)
  return $ h1 ++ "\n" ++ replicate (length h1) '-' ++ "\n" ++ intercalate "\n" (V.toList $ fmap colify rendered)

parseMode :: TF.Parser Mode
parseMode =
  (symbol "tx" >> pure Transactional) <|>
  (symbol "transactional" >> pure Transactional) <|>
  (symbol "local" >> pure Local)

cliCmds :: [(String,String,String,TF.Parser CliCmd)]
cliCmds = [
  ("sleep","[MILLIS]","Pause for 5 sec or MILLIS",
   Sleep . fromIntegral . fromMaybe 5000 <$> optional integer),
  ("cmd","[COMMAND]","Show/set current batch command",
   Cmd <$> optional (some anyChar)),
  ("data","[JSON]","Show/set current JSON data payload",
   Data <$> optional (some anyChar)),
  ("load","YAMLFILE [MODE]",
   "Load and submit yaml file with optional mode (transactional|local), defaults to transactional",
   Load <$> some anyChar <*> (fromMaybe Transactional <$> optional parseMode)),
  ("batch","TIMES","Repeat command in batch message specified times",
   Batch . fromIntegral <$> integer),
  ("par-batch","N:Int B:Int [S:Int]"
  ,"Similar to `batch` but the commands are distributed among the nodes:\n\
   \  * the REPL will create N batch messages\n\
   \  * group them into individual batches of size B\n\
   \  * submit them (in parallel) to each available node\n\
   \ Optional: pause for S milliseconds between submissions to a given server.",
   ParallelBatch <$> (fromIntegral <$> integer)
                 <*> (fromIntegral <$> integer)
                 <*> (fromIntegral <$> integer)
  ),
  ("pollMetrics","REQUESTKEY", "Poll each server for the request key but print latency metrics from each.",
   PollMetrics <$> some anyChar),
  ("poll","REQUESTKEY", "Poll server for request key",
   Poll <$> some anyChar),
  ("exec","COMMAND","Send command transactionally to server",
   Send Transactional <$> some anyChar),
  ("local","COMMAND","Send command locally to server",
   Send Local <$> some anyChar),
  ("server","[SERVERID]","Show server info or set current server",
   Server <$> optional (some anyChar)),
  ("help","","Show command help", pure Help),
  ("keys","[PUBLIC PRIVATE]","Show or set signing keypair",
   Keys <$> optional ((,) <$> (T.pack <$> some alphaNum) <*> (spaces >> (T.pack <$> some alphaNum)))),
  ("exit","","Exit client", pure Exit),
  ("format","[FORMATTER]","Show/set current output formatter (yaml|raw|pretty|table)",
   Format <$> optional ((symbol "yaml" >> pure YAML) <|>
                        (symbol "raw" >> pure Raw) <|>
                        (symbol "pretty" >> pure PrettyJSON) <|>
                        (symbol "table" >> pure Table))),
  ("private","TO [FROM1 FROM2...] CMD","Send private transactional command to server addressed with entity names",
   parsePrivate)
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
            _ -> handleCmd c >> loop True

handleCmd :: CliCmd -> Repl ()
handleCmd cmd = case cmd of
  Help -> help
  Sleep i -> threadDelay (i * 1000)
  Cmd Nothing -> use batchCmd >>= flushStrLn
  Cmd (Just c) -> batchCmd .= c
  Send m c -> sendCmd m c
  Server Nothing -> do
    use server >>= \s -> flushStrLn $ "Current server: " ++ s
    flushStrLn "Servers:"
    view ccEndpoints >>= \es -> forM_ (sort $ HM.toList es) $ \(i,e) -> do
      flushStrLn $ i ++ ": " ++ show e
  Server (Just s) -> server .= s
  Batch n | n <= 50000 -> use batchCmd >>= batchTest n
          | otherwise -> void $ flushStrLn "Aborting: batch count limited to 50000"
  ParallelBatch{..}
   | batchSize >= 10000 -> void $ flushStrLn "Aborting: batch count for parallel issuance too large"
   | sleepBetweenBatches < 250 -> void $ flushStrLn "Aborting: sleep between batches needs to be >= 250"
   | otherwise -> parallelBatchTest totalNumCmds batchSize sleepBetweenBatches
  Load s m -> load m s
  Poll s -> parseRK s >>= void . pollForResult False . RequestKey . Hash
  PollMetrics rk -> do
    s <- use server
    sList <- HM.toList <$> view ccEndpoints
    rk' <- parseRK rk
    forM_ sList $ \(s',_) -> do
      server .= s'
      flushStrLn $ "##############  " ++ s' ++ "  ##############"
      void $ pollForResult True $ RequestKey $ Hash rk'
    server .= s
  Exit -> return ()
  Data Nothing -> use cmdData >>= flushStrLn . BSL.unpack . encode
  Data (Just s) -> either (\e -> flushStrLn $ "Bad JSON value: " ++ show e) (cmdData .=) $ eitherDecode (BSL.pack s)
  Keys Nothing -> use keys >>= mapM_ putJSON
  Keys (Just (p,s)) -> do
    sk <- case fromJSON (String s) of
      A.Error e -> die $ "Bad secret key value: " ++ show e
      A.Success k -> return k
    pk <- case fromJSON (String p) of
      A.Error e -> die $ "Bad public key value: " ++ show e
      A.Success k -> return k
    keys .= [KeyPair sk pk]
  Format Nothing -> use fmt >>= flushStrLn . show
  Format (Just f) -> fmt .= f
  Private to from msg -> sendPrivate (Pact.Address to (S.fromList from)) msg

parseRK :: String -> Repl B.ByteString
parseRK cmd = case B16.decode $ BS8.pack cmd of
  (rk,leftovers)
    | B.empty /= leftovers ->
      die $ "Failed to decode RequestKey: this was converted " ++
      show rk ++ " and this was not " ++ show leftovers
    | B.length rk /= hashLengthAsBS ->
      die $ "RequestKey is too short, should be "
              ++ show hashLengthAsBase16
              ++ " char long but was " ++ show (B.length $ BS8.pack $ drop 7 cmd) ++
              " -> " ++ show (B16.encode rk)
    | otherwise -> return rk

help :: Repl ()
help = do
  flushStrLn "Command Help:"
  forM_ cliCmds $ \(cmd,args,docs,_) -> do
    flushStrLn $ cmd ++ " " ++ args
    flushStrLn $ "    " ++ docs

intervalOfNumerous :: Int64 -> Int64 -> String
intervalOfNumerous cnt mics = let
  interval' = fromIntegral mics / 1000000
  perSec = ceiling (fromIntegral cnt / interval')
  in "Completed in " ++ show (interval' :: Double) ++
     "sec (" ++ show (perSec::Integer) ++ " per sec)"

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
         void $ runStateT (runReaderT runREPL conf) $ ReplState
           {
             _server = fst (minimum $ HM.toList (_ccEndpoints conf)),
             _batchCmd = "\"Hello Kadena\"",
             _requestId = i,
             _cmdData = Null,
             _keys = [KeyPair (_ccSecretKey conf) (_ccPublicKey conf)],
             _fmt = Table
           }
