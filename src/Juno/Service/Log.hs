{-# LANGUAGE BangPatterns #-}

module Juno.Service.Log
  ( runLogService
  , module X)
  where

import Control.Lens hiding (Index, (|>))
import Control.Concurrent (putMVar)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.RWS.Strict

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Sequence (Seq)

import Data.Maybe (fromJust, isJust)
import Data.Thyme.Clock
import Database.SQLite.Simple (Connection(..))

import Juno.Types.Comms
import Juno.Persistence.SQLite
import Juno.Types.Service.Log as X
import qualified Juno.Types.Service.Evidence as Ev
import qualified Juno.Types.Dispatch as Dispatch
import Juno.Types (startIndex, Event(ApplyLogEntries), Dispatch, interval)

runLogService :: Dispatch -> (String -> IO()) -> FilePath -> KeySet -> IO ()
runLogService dispatch dbg dbPath keySet' = do
  dbConn' <- if not (null dbPath)
    then do
      dbg $ "[LogThread] Database Connection Opened: " ++ dbPath
      Just <$> createDB dbPath
    else do
      dbg "[LogThread] Persistence Disabled"
      return Nothing
  cryptoMvar <- newTVarIO Idle
  env <- return $ LogEnv
    { _logQueryChannel = (dispatch ^. Dispatch.logService)
    , _internalEvent = (dispatch ^. Dispatch.internalEvent)
    , _evidence = (dispatch ^. Dispatch.evidence)
    , _debugPrint = dbg
    , _keySet = keySet'
    , _cryptoWorkerTVar = cryptoMvar
    , _dbConn = dbConn'
    }
  link <$> tinyCryptoWorker keySet' dbg (dispatch ^. Dispatch.logService) cryptoMvar
  initLogState' <- case dbConn' of
    Just conn' -> syncLogsFromDisk conn'
    Nothing -> return $ initLogState
  void $ runRWST handle env initLogState'

debug :: String -> LogThread ()
debug s = do
  dbg <- view debugPrint
  liftIO $ dbg $ "[Service|Log]: " ++ s

handle :: LogThread ()
handle = do
  oChan <- view logQueryChannel
  debug "launch!"
  forever $ do
    q <- liftIO $ readComm oChan
    runQuery q

runQuery :: QueryApi -> LogThread ()
runQuery (Query aq mv) = do
  a' <- get
  qr <- return $ Map.fromSet (`evalQuery` a') aq
  liftIO $ putMVar mv qr
runQuery (Update ul) = do
  modify (\a' -> updateLogs ul a')
  updateEvidenceCache ul
  dbConn' <- view dbConn
  case dbConn' of
    Just conn -> do
      toPersist <- getUnpersisted <$> get
      case toPersist of
        Just logs -> do
          lsLastPersisted .= (_leLogIndex $ fromJust $ seqTail logs)
          liftIO $ insertSeqLogEntry conn logs
        Nothing -> return ()
    Nothing ->  return ()
runQuery (NeedCacheEvidence lis mv) = do
  qr <- buildNeedCacheEvidence lis <$> get
  liftIO $ putMVar mv qr
  debug $ "servicing cache miss pertaining to: " ++ show lis
runQuery (Tick t) = do
  t' <- liftIO $ pprintTock t
  debug t'

tinyCryptoWorker :: KeySet -> (String -> IO ()) -> LogServiceChannel -> TVar CryptoWorkerStatus -> IO (Async ())
tinyCryptoWorker ks dbg c mv = async $ forever $ do
  (lastLogIndex', unverifiedLes) <- atomically $ getWork mv
  stTime <- getCurrentTime
  !postVerify <- return $! verifySeqLogEntries ks unverifiedLes
  atomically $ writeTVar mv Idle
  writeComm c $ Update $ UpdateVerified $ VerifiedLogEntries lastLogIndex' postVerify
  endTime <- getCurrentTime
  dbg $ "[Service|Crypto]: processed " ++ show (length unverifiedLes)
      ++ " in " ++ show (interval stTime endTime) ++ "mics"

getWork :: TVar CryptoWorkerStatus -> STM (LogIndex, Seq LogEntry)
getWork t = do
  r <- readTVar t
  case r of
    Unprocessed v -> writeTVar t Processing >> return v
    Idle -> retry
    Processing -> error "CryptoWorker tried to get work but found the TVar Processing"

buildNeedCacheEvidence :: Set LogIndex -> LogState LogEntry -> Map LogIndex ByteString
buildNeedCacheEvidence lis ls = res `seq` res
  where
    res = Map.fromAscList $ go $ Set.toAscList lis
    go [] = []
    go (li:rest) = case lookupEntry li ls of
      Nothing -> go rest
      Just le -> (li,_leHash le) : go rest
{-# INLINE buildNeedCacheEvidence #-}

updateEvidenceCache :: UpdateLogs -> LogThread ()
updateEvidenceCache (UpdateLastApplied _) = return ()
-- In these cases, we need to update the cache because we have something new
updateEvidenceCache (ULNew _) = updateEvidenceCache' >> tellTinyCryptoWorkerToDoMore
updateEvidenceCache (ULReplicate _) = updateEvidenceCache' >> tellTinyCryptoWorkerToDoMore
updateEvidenceCache (UpdateVerified _) = do
  tellJunoToApplyLogEntries
  view cryptoWorkerTVar >>= liftIO . atomically . (`writeTVar` Idle) >> tellTinyCryptoWorkerToDoMore
updateEvidenceCache (ULCommitIdx _) = tellJunoToApplyLogEntries

-- For pattern matching totality checking goodness
updateEvidenceCache' :: LogThread ()
updateEvidenceCache' = do
  lli <- use lsLastLogIndex
  llh <- use lsLastLogHash
  evChan <- view evidence
  liftIO $ writeComm evChan $ Ev.CacheNewHash lli llh
  debug $ "Sent new evidence to cache for: " ++ show lli

syncLogsFromDisk :: Connection -> IO (LogState LogEntry)
syncLogsFromDisk conn = do
  logs <- selectAllLogEntries conn
  lastLog' <- return $ seqTail logs
  case lastLog' of
    Just log' -> return $ LogState
      { _lsLogEntries = Log logs
      , _lsLastApplied = startIndex
      , _lsLastLogIndex = _leLogIndex log'
      , _lsLastLogHash = _leHash log'
      , _lsNextLogIndex = (_leLogIndex log') + 1
      , _lsCommitIndex = _leLogIndex log'
      , _lsLastPersisted = _leLogIndex log'
      , _lsLastCryptoVerified = _leLogIndex log'
      , _lsLastLogTerm = _leTerm log'
      }
    Nothing -> return $ initLogState

tellJunoToApplyLogEntries :: LogThread ()
tellJunoToApplyLogEntries = do
  es <- get
  case getUnappliedEntries es of
    Just (commitIndex', unappliedEntries') -> do
      view internalEvent >>= liftIO . (`writeComm` (InternalEvent $ ApplyLogEntries (Just unappliedEntries') commitIndex'))
      debug $ "informing Juno of a CommitIndex update: " ++ show commitIndex'
    Nothing -> return ()

tellTinyCryptoWorkerToDoMore :: LogThread ()
tellTinyCryptoWorkerToDoMore = do
  mv <- view cryptoWorkerTVar
  es <- get
  unverifiedLes' <- return $! getUnverifiedEntries es
  case unverifiedLes' of
    Nothing -> return ()
    Just v -> do
      res <- liftIO $ atomically $ do
        r <- readTVar mv
        case r of
          Unprocessed _ -> writeTVar mv (Unprocessed v) >> return "Added more work the Crypto's TVar"
          Idle -> writeTVar mv (Unprocessed v) >> return "CryptoWorker was Idle, gave it something to do"
          Processing -> return "Crypto hasn't finished yet..."
      debug res
