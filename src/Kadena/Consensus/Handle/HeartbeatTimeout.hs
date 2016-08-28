{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Consensus.Handle.HeartbeatTimeout
    (handle)
where

import Control.Concurrent (tryTakeMVar)
import Control.Lens
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer

import Kadena.Consensus.Handle.Types
import qualified Kadena.Service.Sender as Sender
import Kadena.Runtime.Timer (resetHeartbeatTimer, hasElectionTimerLeaderFired)
import Kadena.Util.Util (debug,enqueueEvent, enqueueRequest)
import qualified Kadena.Types as KD

data HeartbeatTimeoutEnv = HeartbeatTimeoutEnv {
      _nodeRole :: Role
    , _leaderWithoutFollowers :: Bool
}
makeLenses ''HeartbeatTimeoutEnv

data HeartbeatTimeoutOut = IsLeader | NotLeader | NoFollowers

handleHeartbeatTimeout :: (MonadReader HeartbeatTimeoutEnv m, MonadWriter [String] m) => String -> m HeartbeatTimeoutOut
handleHeartbeatTimeout s = do
  tell ["heartbeat timeout: " ++ s]
  role' <- view nodeRole
  leaderWithoutFollowers' <- view leaderWithoutFollowers
  case role' of
    Leader -> if leaderWithoutFollowers'
              then tell ["Leader found to not have followers"] >> return NoFollowers
              else return IsLeader
    _ -> return NotLeader

handle :: String -> KD.Consensus ()
handle msg = do
  s <- get
  leaderWithoutFollowers' <- hasElectionTimerLeaderFired
  (out,l) <- runReaderT (runWriterT (handleHeartbeatTimeout msg)) $
             HeartbeatTimeoutEnv
             (KD._nodeRole s)
             leaderWithoutFollowers'
  mapM_ debug l
  case out of
    IsLeader -> do
      enqueueRequest $ Sender.BroadcastAE Sender.SendAERegardless
      resetHeartbeatTimer
      hbMicrosecs <- KD.viewConfig KD.heartbeatTimeout
      r <- view KD.mResetLeaderNoFollowers >>= liftIO . tryTakeMVar
      case r of
        Nothing -> KD.timeSinceLastAER %= (+ hbMicrosecs)
        Just KD.ResetLeaderNoFollowersTimeout -> KD.timeSinceLastAER .= 0
    NotLeader -> KD.timeSinceLastAER .= 0 -- probably overkill, but nice to know this gets set to 0 if not leader
    NoFollowers -> do
      timeout' <- return $ KD._timeSinceLastAER s
      enqueueEvent $ ElectionTimeout $ "Leader has not hear from followers in: " ++ show (timeout' `div` 1000) ++ "ms"
