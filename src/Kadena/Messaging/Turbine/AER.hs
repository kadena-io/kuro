{-# LANGUAGE RecordWildCards #-}

module Kadena.Messaging.Turbine.AER
  ( aerTurbine
  ) where

import Control.Lens
import Control.Monad
import Control.Monad.Reader
import Control.Parallel.Strategies
import Data.Either (partitionEithers)

import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set

import Data.Thyme.Clock (getCurrentTime)

import Kadena.Types hiding (debugPrint, nodeId)
import Kadena.Evidence.Types (Evidence(VerifiedAER))

import Kadena.Messaging.Turbine.Types

aerTurbine :: ReaderT ReceiverEnv IO ()
aerTurbine = do
  getAers' <- view (dispatch.inboundAER)
  let getAers n = readComms getAers' n
  enqueueEvent' <- view (dispatch.evidence)
  let enqueueEvent = writeComm enqueueEvent' . VerifiedAER
  debug <- view debugPrint
  ks <- view keySet
  forever $ liftIO $ do
    -- basically get every AER
    rawAers <- getAers 2000
    startTime <- getCurrentTime
    (invalidAers, unverifiedAers) <- return $! constructEvidenceMap rawAers
    (badCrypto, validAers) <- return $! partitionEithers $! ((getFirstValidAer ks <$> Map.elems unverifiedAers) `using` parList rseq)
    enqueueEvent validAers
    mapM_ (debug . (turbineAer ++)) invalidAers
    mapM_ (debug . (turbineAer ++)) $ concat badCrypto
    endTime <- getCurrentTime
    timeDelta <- return $! interval startTime endTime
    debug $ turbineAer ++ "received " ++ show (length rawAers) ++ " AER(s) & processed them into the "
          ++ show (length validAers) ++ " AER(s) taking " ++ show timeDelta ++ "mics"

constructEvidenceMap :: Seq InboundAER -> ([String], Map NodeId (Set AppendEntriesResponse))
constructEvidenceMap srpcs = go srpcs Map.empty []
  where
    go s m errs = case Seq.viewl s of
      Seq.EmptyL -> (errs,m)
      InboundAER (ts,srpc) Seq.:< rest -> case aerDecodeNoVerify (ts, srpc) of
        Left err -> go rest m (err:errs)
        Right aer -> go rest (Map.insertWith Set.union (_aerNodeId aer) (Set.singleton aer) m) errs
{-# INLINE constructEvidenceMap #-}

getFirstValidAer :: KeySet -> Set AppendEntriesResponse -> Either [String] AppendEntriesResponse
getFirstValidAer ks sAer = go (Set.toDescList sAer) []
  where
    go [] errs = Left errs
    go (aer:rest) errs = case aerReverify ks aer of
      Left err -> go rest (err:errs)
      Right aer' -> Right aer'
{-# INLINE getFirstValidAer #-}
