
module Juno.Types.Event
  ( Event(..)
  ) where

import Juno.Types.Message

data Event = ERPC RPC
           | AERs AlotOfAERs
           | ElectionTimeout String
           | HeartbeatTimeout String
           | Tock -- used initially for the timer system to work (it uses a blocking channel read so on idle nothing happens)
  deriving (Show)
