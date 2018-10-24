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

import Kadena.Types
import qualified Kadena.Config.TMVar as TMV
import Kadena.Consensus.Handle.AppendEntries (clearLazyVoteAndInformCandidates)
import qualified Kadena.Types.Sender as Sender (ServiceRequest(..), AEBroadcastControl(..))
import Kadena.Consensus.Util
import qualified Kadena.Types as KD

data HeartbeatTimeoutEnv = HeartbeatTimeoutEnv {
      _nodeRole :: Role
    , _leaderWithoutFollowers :: Bool
}
makeLenses ''HeartbeatTimeoutEnv

data HeartbeatTimeoutOut = IsLeader | NotLeader | NoFollowers

handleHeartbeatTimeout :: (MonadReader HeartbeatTimeoutEnv m, MonadWriter [String] m) => String -> m HeartbeatTimeoutOut
handleHeartbeatTimeout _s = do
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
             (_csNodeRole s)
             leaderWithoutFollowers'
  mapM_ debug l
  theNodeId <- KD.viewConfig TMV.nodeId 
  let theAlias  = show (_alias theNodeId)
  case out of
    IsLeader -> do
      debug (theAlias ++ ": (leader) enqueuing SendAERegardless")
      enqueueRequest $ Sender.BroadcastAE Sender.SendAERegardless
      enqueueRequest $ Sender.BroadcastAER
      clearLazyVoteAndInformCandidates
      resetHeartbeatTimer
      hbMicrosecs <- KD.viewConfig TMV.heartbeatTimeout
      r <- view KD.mResetLeaderNoFollowers >>= liftIO . tryTakeMVar
      case r of
        Nothing -> csTimeSinceLastAER %= (+ hbMicrosecs)
        Just KD.ResetLeaderNoFollowersTimeout -> csTimeSinceLastAER .= 0
    NotLeader -> csTimeSinceLastAER .= 0 -- probably overkill, but nice to know this gets set to 0 if not leader
    NoFollowers -> do
      debug (theAlias ++ ": (leader) enqueuing ElectionTimeout")
      timeout' <- return $ _csTimeSinceLastAER s
      enqueueEvent $ ElectionTimeout $ "*%* Leader has not heard from followers in: " ++ show (timeout' `div` 1000) ++ "ms"
