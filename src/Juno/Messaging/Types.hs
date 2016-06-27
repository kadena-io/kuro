{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}

module Juno.Messaging.Types (
  Spec(..)
  ,Addr(..)
  ,OutBoundMsg(..)
  ,Recipients(..)
  ,ListenOn(..)
  ,Rolodex(..)
  ) where

import Control.Concurrent.Chan.Unagi
import Data.Serialize
import Juno.Types (ReceivedAt, Addr(..), Rolodex(..), Recipients(..), OutBoundMsg(..), ListenOn(..))

data Spec addr msg sock = Spec {
  -- | Messages for you
  _sInbox   :: Serialize msg => InChan (ReceivedAt, msg)
  -- | Messages that you want to send
  ,_sOutbox :: Serialize addr => OutChan (OutBoundMsg addr msg)
  -- | What the receiver listens on
  ,_sWhoAmI :: Addr addr
  ,_sRolodex :: Rolodex addr sock
  }
