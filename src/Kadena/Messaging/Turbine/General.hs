{-# LANGUAGE RecordWildCards #-}

module Kadena.Messaging.Turbine.General
  ( generalTurbine
  ) where

import Control.Lens
import Control.Monad
import Control.Monad.Reader

import Data.Either (partitionEithers)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map

import Data.Thyme.Clock (getCurrentTime)

import Kadena.Types hiding (debugPrint, nodeId)
import Kadena.PreProc.Types (ProcessRequestChannel(..), ProcessRequest(..))
import Kadena.Messaging.Turbine.Types

generalTurbine :: ReaderT ReceiverEnv IO ()
generalTurbine = do
  gm' <- view (dispatch.inboundGeneral)
  prChan <- view (dispatch.processRequestChannel)
  let gm n = readComms gm' n
  enqueueEvent' <- view (dispatch.internalEvent)
  let enqueueEvent = writeComm enqueueEvent' . InternalEvent
  debug <- view debugPrint
  ks <- view keySet
  forever $ liftIO $ do
    msgs <- gm 10
    (aes, noAes) <- return $ Seq.partition (\(_,SignedRPC{..}) -> (_digType _sigDigest == AE)) (_unInboundGeneral <$> msgs)
    prunedAes <- return $ pruneRedundantAEs aes
    when (length aes - length prunedAes /= 0) $ debug $ turbineGeneral ++ "pruned " ++ show (length aes - length prunedAes) ++ " redundant AE(s)"
    unless (null aes) $ do
      l <- return $ show (length aes)
      forM_ prunedAes $ \(ts,msg) -> case signedRPCtoRPC (Just ts) ks msg of
        Left err -> debug err
        Right (AE' ae'@AppendEntries{..}) -> do
          newLes' <- startPreProcForLes prChan _aeEntries
          newAE' <- return $ ae' { _aeEntries = newLes' }
          t' <- getCurrentTime
          debug $ turbineGeneral ++ "enqueued 1 of " ++ l ++ " AE(s) taking "
                ++ show (interval (_unReceivedAt ts) t')
                ++ "mics since it was received"
          enqueueEvent (ERPC $ AE' newAE')
        Right err -> error $ "unreachable error in GeneralTurbine's 2nd AE match: " ++ show err
    (invalid, validNoAes) <- return $ partitionEithers $ parallelVerify id ks noAes
    unless (null validNoAes) $ mapM_ (enqueueEvent . ERPC) validNoAes
    unless (null invalid) $ mapM_ debug invalid

{-# INLINE pruneRedundantAEs #-}
pruneRedundantAEs :: Seq (ReceivedAt, SignedRPC) -> [(ReceivedAt, SignedRPC)]
pruneRedundantAEs m = go m Set.empty
  where
    getSig = _digSig . _sigDigest . snd
    go aeSeq s = case Seq.viewl aeSeq of
      Seq.EmptyL -> []
      ae Seq.:< aes -> if Set.member (getSig ae) s then go aes (Set.insert (getSig ae) s) else ae : go aes (Set.insert (getSig ae) s)

startPreProcForLes :: ProcessRequestChannel -> LogEntries -> IO LogEntries
startPreProcForLes prChan les = do
  (newLes', mapRpps) <- preprocLogEntries les
  forM_ (Map.toAscList $ mapRpps) $ writeComm prChan . CommandPreProc . snd
  return newLes'
