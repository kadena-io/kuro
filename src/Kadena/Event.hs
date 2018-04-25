{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Kadena.Event
  ( pprintBeat
  , createBeat
  , foreverHeart
  , foreverHeartDebugWriteDelay
  ) where

import Control.Monad
import Control.Lens
import Control.Concurrent (threadDelay)
import Data.AffineSpace ((.-.))
import Data.Thyme.Clock (UTCTime, microseconds, getCurrentTime)

import Kadena.Types.Event
import Kadena.Types.Comms

-- Beats are useful for seeing how backed up things are
pprintBeat :: Beat -> IO String
pprintBeat Beat{..} = do
  t' <- getCurrentTime
  (delay :: Int) <- return $! (fromIntegral $ view microseconds $ t' .-. _tockStartTime)
  return $! "Heartbeat delayed by " ++ show delay ++ "mics"

createBeat :: Int -> IO Beat
createBeat delay = Beat <$> pure delay <*> getCurrentTime

fireHeart :: (Comms a b) => b -> Int -> (Beat -> a) -> IO UTCTime
fireHeart comm delay mkBeat = do
  !t@(Beat _ st) <- createBeat delay
  writeComm comm $ mkBeat t
  return st

foreverHeart :: Comms a b => b -> Int -> (Beat -> a) -> IO ()
foreverHeart comm delay mkBeat = forever $ do
  _ <- fireHeart comm delay mkBeat
  threadDelay delay

foreverHeartDebugWriteDelay :: Comms a b => (String -> IO ()) -> b -> Int -> (Beat -> a) -> IO ()
foreverHeartDebugWriteDelay debug' comm delay mkBeat = forever $ do
  !st <- fireHeart comm delay mkBeat
  !t' <- getCurrentTime
  !(writeDelay :: Int) <- return $! (fromIntegral $ view microseconds $ t' .-. st)
  debug' $ "writing heartbeat to channel took " ++ show writeDelay ++ "mics"
  threadDelay delay