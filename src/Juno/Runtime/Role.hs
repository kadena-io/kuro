
module Juno.Runtime.Role
  ( becomeFollower
  ) where

import Juno.Runtime.Timer
import Juno.Types
import Juno.Util.Util

becomeFollower :: Raft ()
becomeFollower = do
  debug "becoming follower"
  setRole Follower
  resetElectionTimer
