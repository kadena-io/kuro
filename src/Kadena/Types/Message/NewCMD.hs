{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Message.NewCMD
  ( NewCmd(..), newCmds, newProvenance
  ) where

import Codec.Compression.LZ4
import Control.Lens
import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import Data.Thyme.Time.Core ()
import GHC.Generics

import Kadena.Types.Command
import Kadena.Types.Base
import Kadena.Types.Message.Signed

data NewCmd = NewCmd
  { _newCmds :: ![Command]
  , _newProvenance  :: !Provenance
  }
  deriving (Show, Eq, Generic)
makeLenses ''NewCmd

data NewCMDWire = NewCMDWire ![CMDWire]
  deriving (Show, Generic)
instance Serialize NewCMDWire

instance WireFormat NewCmd where
  toWire nid pubKey privKey NewCmd{..} = case _newProvenance of
    NewMsg -> let bdy = S.encode $ NewCMDWire $ encodeCommand <$> _newCmds
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
        Right (NewCMDWire cmdwire') -> Right $ NewCmd (decodeCommand <$> cmdwire') $ ReceivedMsg dig bdy ts
  {-# INLINE toWire #-}
  {-# INLINE fromWire #-}
