{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Juno.Service.Evidence
  ( startProcessor
  , initEvidenceEnv
  , module X
  -- for benchmarks
  , _runEvidenceProcessTest
  ) where

import Control.Concurrent (MVar, readMVar, newEmptyMVar, takeMVar, swapMVar)
import Control.Lens hiding (Index)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Reader
import Control.Monad.Trans.State.Strict

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set

import Juno.Types.Dispatch (Dispatch)
import Juno.Types.Service.Evidence as X
import qualified Juno.Types.Dispatch as Dispatch
import qualified Juno.Types.Service.Log as Log

initEvidenceEnv :: Dispatch -> (String -> IO ()) -> MVar Config -> MVar EvidenceState -> MVar EvidenceCache -> EvidenceEnv
initEvidenceEnv dispatch debugFn' mConfig' mPubStateTo' mEvCache' = EvidenceEnv
  { _logService = dispatch ^. Dispatch.logService
  , _evidence = dispatch ^. Dispatch.evidence
  , _mConfig = mConfig'
  , _mPubStateTo = mPubStateTo'
  , _mEvCache = mEvCache'
  , _debugFn = debugFn'
  }

rebuildState :: Maybe EvidenceState -> EvidenceProcEnv (EvidenceState)
rebuildState es = do
  conf' <- view mConfig >>= liftIO . readMVar
  otherNodes' <- return $ _otherNodes conf'
  mv <- queryLogs $ Set.singleton Log.GetCommitIndex
  commitIndex' <- return $ Log.hasQueryResult Log.CommitIndex mv
  newEs <- return $! initEvidenceState otherNodes' commitIndex'
  case es of
    Just es' -> return $! es'
        { _esQuorumSize = _esQuorumSize newEs
        }
    Nothing -> return $! newEs

runEvidenceProcessor :: EvidenceState -> EvidenceProcEnv (EvidenceState)
runEvidenceProcessor es = do
  newEv <- view evidence >>= liftIO . readComm
  case newEv of
    VerifiedAER aers -> do
      esPub <- view mPubStateTo
      ec <- view mEvCache >>= liftIO . readMVar
      (res, newEs) <- return $! runState (processEvidence aers ec) es
      liftIO $ void $ swapMVar esPub newEs
      case res of
        Left i -> do
          debug $ "Evidence still required " ++ (show i) ++ " of " ++ show (1 + _esQuorumSize newEs)
          runEvidenceProcessor newEs
        Right li -> do
          updateLogs $ Log.ULCommitIdx $ Log.UpdateCommitIndex li
          debug $ "CommitIndex = " ++ (show li)
          runEvidenceProcessor newEs
    Tick tock -> do
      liftIO (pprintTock tock "runEvidenceProcessor") >>= debug
      runEvidenceProcessor es
    Bounce -> return es

startProcessor :: EvidenceEnv -> IO ()
startProcessor ev = do
  startingEs <- runReaderT (rebuildState Nothing) ev
  runReaderT (foreverRunProcessor startingEs) ev

foreverRunProcessor :: EvidenceState -> EvidenceProcEnv ()
foreverRunProcessor es = runEvidenceProcessor es >>= rebuildState . Just >>= foreverRunProcessor

queryLogs :: Set Log.AtomicQuery -> EvidenceProcEnv (Map Log.AtomicQuery Log.QueryResult)
queryLogs aq = do
  c <- view logService
  mv <- liftIO $ newEmptyMVar
  liftIO $ writeComm c $ Log.Query aq mv
  liftIO $ takeMVar mv

updateLogs :: Log.UpdateLogs -> EvidenceProcEnv ()
updateLogs q = do
  logService' <- view logService
  liftIO $ writeComm logService' $ Log.Update q

debug :: String -> EvidenceProcEnv ()
debug s = do
  debugFn' <- view debugFn
  liftIO $ debugFn' $ "[EV_SERVICE]: " ++ s

checkForNewCommitIndex :: Int -> Map LogIndex Int -> Either Int LogIndex
checkForNewCommitIndex evidenceNeeded partialEvidence = go (Map.toDescList partialEvidence) evidenceNeeded
  where
    go [] eStillNeeded = Left eStillNeeded
    go ((li, cnt):pes) en
      | en - cnt <= 0 = Right li
      | otherwise     = go pes (en - cnt)
{-# INLINE checkForNewCommitIndex #-}

processEvidence :: [AppendEntriesResponse] -> EvidenceCache -> EvidenceProcessor (Either Int LogIndex)
processEvidence aers ec = do
  es <- get
  mapM_ processResult (checkEvidence ec es <$> aers)
  res <- checkForNewCommitIndex (_esQuorumSize es) <$> use esPartialEvidence
  case res of
    Left i -> return $ Left i
    Right li -> do
      esCommitIndex .= li
      -- though the code in `processResult Successful` should be enough to keep everything in sync
      -- we're going to make doubly sure that we don't double count
      esPartialEvidence %= Map.filterWithKey (\k _ -> k > li)
      return $ Right li
{-# INLINE processEvidence #-}




-- For Testing

_runEvidenceProcessTest
  :: (EvidenceState, EvidenceCache, [AppendEntriesResponse])
  -> (Either Int LogIndex, EvidenceState)
_runEvidenceProcessTest (es, ec, aers) = runState (processEvidence aers ec) es

_checkEvidence :: (EvidenceState, EvidenceCache, AppendEntriesResponse) -> Result
_checkEvidence (es, ec, aer) = checkEvidence ec es aer
