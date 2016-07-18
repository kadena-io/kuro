{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Juno.Consensus.Commit
  (applyLogEntries
  ,makeCommandResponse
  ,makeCommandResponse')
where

import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import Data.Int (Int64)
import Data.Thyme.Clock (UTCTime)

import qualified Data.ByteString.Char8 as BSC
import Data.Sequence (Seq)
import qualified Data.Map.Strict as Map
import Data.Foldable (toList)

import Juno.Types hiding (valid)
import Juno.Util.Util
import qualified Juno.Service.Sender as Sender
import qualified Juno.Service.Log as Log


applyLogEntries :: Maybe (Seq LogEntry) -> LogIndex -> Raft ()
applyLogEntries unappliedEntries' commitIndex' = do
  now <- view (rs.getTimestamp) >>= liftIO
  case unappliedEntries' of
    Nothing -> debug $ "No new entries to apply"
    Just leToApply -> do
      results <- mapM (applyCommand now . _leCommand) leToApply
      r <- use nodeRole
      updateLogs $ Log.UpdateLastApplied commitIndex'
      logMetric $ MetricAppliedIndex commitIndex'
      if not (null results)
        then if r == Leader
            then do
              enqueueRequest $! Sender.SendCommandResults $! toList results
              debug $ "Applied and Responded to " ++ show (length results) ++ " CMD(s)"
            else debug $ "Applied " ++ show (length results) ++ " CMD(s)"
        else debug "Applied log entries but did not send results?"

logApplyLatency :: Command -> Raft ()
logApplyLatency (Command _ _ _ _ provenance) = case provenance of
  NewMsg -> return ()
  ReceivedMsg _digest _orig mReceivedAt -> case mReceivedAt of
    Just (ReceivedAt arrived) -> do
      now <- view (rs.getTimestamp) >>= liftIO
      logMetric $ MetricApplyLatency $ fromIntegral $ interval arrived now
    Nothing -> return ()

applyCommand :: UTCTime -> Command -> Raft (NodeId, CommandResponse)
applyCommand tEnd cmd@Command{..} = do
  apply <- view (rs.applyLogEntry)
  me <- _alias <$> viewConfig nodeId
  encKey <- viewConfig myEncryptionKey
  logApplyLatency cmd
  result <- case decryptCommand me encKey cmd of
              Left res -> return res
              Right v -> liftIO $ apply $ cmd {_cmdEntry = v }
  updateCmdStatusMap cmd result tEnd -- shared with the API and to query state
  replayMap %= Map.insert (_cmdClientId, getCmdSigOrInvariantError "applyCommand" cmd) (Just result)
  ((,) _cmdClientId) <$> makeCommandResponse tEnd cmd result

decryptCommand :: Alias -> EncryptionKey -> Command -> Either CommandResult CommandEntry
decryptCommand me encKey Command{..}
    | _cmdEncryptGroup == Nothing = Right _cmdEntry
    | Just me == _cmdEncryptGroup = case decrypt' encKey (unCommandEntry $ _cmdEntry) of
        Right v -> Right $ CommandEntry v
        Left err -> Left $ CommandResult $ BSC.pack $ "Failed to decrypt private Command: " ++ err
    | otherwise = Left $ CommandResult "Not party to Private Command"
  where
    decrypt' _ v = Right v

updateCmdStatusMap :: Command -> CommandResult -> UTCTime -> Raft ()
updateCmdStatusMap cmd cmdResult tEnd = do
  rid <- return $ _cmdRequestId cmd
  mvarMap <- view (rs.cmdStatusMap)
  updateMapFn <- view (rs.updateCmdMap)
  lat <- return $ case _pTimeStamp $ _cmdProvenance cmd of
    Nothing -> 1 -- don't want a div by zero error downstream and this is for demo purposes
    Just (ReceivedAt tStart) -> interval tStart tEnd
  liftIO $ void $ updateMapFn mvarMap rid (CmdApplied cmdResult lat)

makeCommandResponse :: UTCTime -> Command -> CommandResult -> Raft CommandResponse
makeCommandResponse tEnd cmd result = do
  nid <- viewConfig nodeId
  mlid <- use currentLeader
  lat <- return $ case _pTimeStamp $ _cmdProvenance cmd of
    Nothing -> 1 -- don't want a div by zero error downstream and this is for demo purposes
    Just (ReceivedAt tStart) -> interval tStart tEnd
  return $ makeCommandResponse' nid mlid cmd result lat

makeCommandResponse' :: NodeId -> Maybe NodeId -> Command -> CommandResult -> Int64 -> CommandResponse
makeCommandResponse' nid mlid Command{..} result lat = CommandResponse
             result
             (maybe nid id mlid)
             nid
             _cmdRequestId
             lat
             NewMsg


-- TODO: replicate metrics integration in Evidence
--logCommitChange :: LogIndex -> LogIndex -> Raft ()
--logCommitChange before after
--  | after > before = do
--      logMetric $ MetricCommitIndex after
--      mLastTime <- use lastCommitTime
--      now <- view (rs.getTimestamp) >>= liftIO
--      case mLastTime of
--        Nothing -> return ()
--        Just lastTime ->
--          let duration = interval lastTime now
--              (LogIndex numCommits) = after - before
--              period = fromIntegral duration / fromIntegral numCommits
--          in logMetric $ MetricCommitPeriod period
--      lastCommitTime ?= now
--  | otherwise = return ()
--
--updateCommitIndex' :: Raft Bool
--updateCommitIndex' = do
--  proof <- use commitProof
--  -- We don't need a quorum of AER's, but quorum-1 because we check against our own logs (thus assumes +1 at the start)
--  -- TODO: test this idea out
--  --qsize <- view quorumSize >>= \n -> return $ n - 1
--  qsize <- view quorumSize >>= \n -> return $ n - 1
--
--  evidence <- return $! reverse $ sortOn _aerIndex $ Map.elems proof
--
--  mv <- queryLogs $ Set.fromList $ (Log.GetCommitIndex):(Log.GetMaxIndex):((\aer -> Log.GetSomeEntry $ _aerIndex aer) <$> evidence)
--  ci <- return $ Log.hasQueryResult Log.CommitIndex mv
--  maxLogIndex <- return $ Log.hasQueryResult Log.MaxIndex mv
--
--  case checkCommitProof qsize mv maxLogIndex evidence of
--    Left 0 -> do
--      debug $ "Commit Proof Checked: no new evidence " ++ show ci
--      return False
--    Left n -> if maxLogIndex > fromIntegral ci
--              then do
--                debug $ "Not enough evidence to commit yet, need " ++ show (qsize - n) ++ " more"
--                return False
--              else do
--                debug $ "Commit Proof Checked: stead state with MaxLogIndex " ++ show maxLogIndex ++ " == CommitIndex " ++ show ci
--                return False
--    Right qci -> if qci > ci
--                then do
--                  updateLogs $ ULCommitIdx $ UpdateCommitIndex qci
--                  logCommitChange ci qci
--                  commitProof %= Map.filter (\a -> qci < _aerIndex a)
--                  debug $ "Commit index is now: " ++ show qci
--                  return True
--                else do
--                  debug $ "Commit index is " ++ show qci ++ " with evidence for " ++ show ci
--                  return False
--
--checkCommitProof :: Int -> Map Log.AtomicQuery Log.QueryResult  -> LogIndex -> [AppendEntriesResponse] -> Either Int LogIndex
--checkCommitProof qsize mv maxLogIdx evidence = go 0 evidence
--  where
--    go n [] = Left n
--    go n (ev:evs) = if _aerIndex ev > maxLogIdx
--                    then go n evs
--                    else if Just (_aerHash ev) == (_leHash <$> Log.hasQueryResult (Log.SomeEntry (_aerIndex ev)) mv)
--                         then if (n+1) >= qsize
--                              then Right $ _aerIndex ev
--                              else go (n+1) evs
--                         else go n evs
