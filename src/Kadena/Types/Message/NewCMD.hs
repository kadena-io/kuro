{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

module Kadena.Types.Message.NewCMD
  ( NewCmdInternal(..), newCmdInternal
  , NewCmdRPC(..), newCmd, newProvenance
  , NewCmdWire(..)
  ) where

import Control.Lens
import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import Data.Thyme.Time.Core ()
import GHC.Generics

import Pact.Types.Hash as P

import Kadena.Crypto
import Kadena.Types.Base
import Kadena.Types.Command
import Kadena.Types.Message.Signed

-- | This is what you use to send new commands into consensus' state machine
data NewCmdInternal = NewCmdInternal
  { _newCmdInternal :: ![CMDWire]
  }
  deriving (Show, Eq, Generic)
makeLenses ''NewCmdInternal

-- | This is what a follower uses to forward commands it's received to the leader
data NewCmdRPC = NewCmdRPC
  { _newCmd :: ![CMDWire]
  , _newProvenance :: !Provenance
  }
  deriving (Show, Eq, Generic)
makeLenses ''NewCmdRPC

data NewCmdWire = NewCmdWire ![CMDWire]
  deriving (Show, Generic)
instance Serialize NewCmdWire

instance WireFormat NewCmdRPC where
  toWire nid pubKey privKey NewCmdRPC{..} = case _newProvenance of
    NewMsg -> let bdy = S.encode $ NewCmdWire $ _newCmd
                  hsh = P.pactHash bdy
                  sig = sign hsh privKey pubKey
                  dig = Digest (_alias nid) sig pubKey NEW hsh
              in SignedRPC dig bdy
    ReceivedMsg{..} -> SignedRPC _pDig _pOrig
  fromWire !ts !ks s@(SignedRPC !dig !bdy) = case verifySignedRPC ks s of
    Left !err -> Left err
    Right () -> if _digType dig /= NEW
      then error $ "Invariant Failure: attempting to decode " ++ show (_digType dig) ++ " with CMDWire instance"
      else case S.decode bdy of
        Left err -> Left $! "Failure to decode NewCMDWire: " ++ err
        Right (NewCmdWire cmdwire') -> Right $! NewCmdRPC cmdwire' $ ReceivedMsg dig bdy ts
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}
