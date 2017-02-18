{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Message.NewCMD
  ( NewCmdInternal(..), newCmdInternal
  , NewCmdRPC(..), newCmd, newProvenance
  , NewCmdWire(..)
  ) where

import Codec.Compression.LZ4
import Control.Lens
import Data.Serialize (Serialize)
import Data.Either
import qualified Data.Serialize as S
import Data.Thyme.Time.Core ()
import GHC.Generics

import Kadena.Types.Command
import Kadena.Types.Base
import Kadena.Types.Message.Signed

data NewCmdInternal = NewCmdInternal
  { _newCmdInternal :: ![Command]
  }
  deriving (Show, Eq, Generic)
makeLenses ''NewCmdInternal

data NewCmdRPC = NewCmdRPC
  { _newCmd :: ![Command]
  , _newProvenance :: !Provenance
  }
  deriving (Show, Eq, Generic)
makeLenses ''NewCmdRPC

data NewCmdWire = NewCmdWire ![CMDWire]
  deriving (Show, Generic)
instance Serialize NewCmdWire

instance WireFormat NewCmdRPC where
  toWire nid pubKey privKey NewCmdRPC{..} = case _newProvenance of
    NewMsg -> let bdy = S.encode $ NewCmdWire $ encodeCommand <$> _newCmd
                  hsh = hash bdy
                  sig = sign hsh privKey pubKey
                  dig = Digest (_alias nid) sig pubKey AE hsh
              in SignedRPC dig bdy
    ReceivedMsg{..} -> SignedRPC _pDig _pOrig
  fromWire !ts !ks s@(SignedRPC !dig !bdy) = case verifySignedRPC ks s of
    Left !err -> Left err
    Right () -> if _digType dig /= NEW
      then error $ "Invariant Failure: attempting to decode " ++ show (_digType dig) ++ " with AEWire instance"
      else case maybe (Left "Decompression failure") S.decode $ decompress bdy of
        Left err -> Left $! "Failure to decode NewCMDWire: " ++ err
        Right (NewCmdWire cmdwire') ->
          let (lefts,rights) = partitionEithers (decodeCommandEither <$> cmdwire')
          in
            if null lefts
            then Right $! NewCmdRPC rights $ ReceivedMsg dig bdy ts
            else Left $! "Failure to decode Commands: " ++ show lefts
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}
