{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Kadena.Util.Util
  ( seqIndex
  , getQuorumSize
  , awsDashVar
  , fromMaybeM
  , foreverRetry
  ) where

import Control.Monad
import Control.Concurrent (forkFinally, putMVar, takeMVar, newEmptyMVar, forkIO)
import System.Process (system)

import Data.Sequence (Seq)
import qualified Data.Sequence as Seq

--TODO: this is pretty ghetto, there has to be a better/cleaner way
foreverRetry :: (String -> IO ()) -> String -> IO () -> IO ()
foreverRetry debug threadName action = void $ forkIO $ forever $ do
  threadDied <- newEmptyMVar
  void $ forkFinally (debug (threadName ++ " launching") >> action >> putMVar threadDied ())
    $ \res -> do
      case res of
        Right () -> debug $ threadName ++ " died returning () with no details"
        Left err -> debug $ threadName ++ " exception " ++ show err
      putMVar threadDied ()
  takeMVar threadDied
  debug $ threadName ++ "got MVar... restarting"

awsDashVar :: Bool -> String -> String -> IO ()
awsDashVar False _ _ = return ()
awsDashVar True  k v = void $! forkIO $! void $! system $
  "aws ec2 create-tags --resources `ec2-metadata --instance-id | sed 's/^.*: //g'` --tags Key="
  ++ k
  ++ ",Value="
  ++ v
  ++ " >/dev/null"

seqIndex :: Seq a -> Int -> Maybe a
seqIndex s i =
  if i >= 0 && i < Seq.length s
    then Just (Seq.index s i)
    else Nothing

getQuorumSize :: Int -> Int
getQuorumSize n = 1 + floor (fromIntegral n / 2 :: Float)

fromMaybeM :: Monad m => m b -> Maybe b -> m b
fromMaybeM errM = maybe errM (return $!)
