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

import Kadena.Config.TMVar (Config(..))
import Kadena.Types.Base
import Kadena.Types.Event
import Kadena.Types.Comms

-- Beats are useful for seeing how backed up things are
pprintBeat :: Beat -> Config -> IO String
pprintBeat b Config{..} = do
  let nodeId = _alias _nodeId
  t' <- getCurrentTime
  (delay :: Int) <- return $! (fromIntegral $ view microseconds $ t' .-. (_tockStartTime b))
  let str = show nodeId ++ ": Heartbeat delayed by " ++ show delay ++ " microseconds"
  let seconds :: Integer = round ((fromIntegral delay :: Double) / fromIntegral (1000000 :: Int))
  let str' = if seconds < 1 then str
               else str ++ " (~ " ++ show seconds ++ " second(s))"
  let electionMax = snd _electionTimeoutRange * 2
  let str'' = if delay <= electionMax then str'
                else str' ++ "\n ***** Warning: " ++ show nodeId
                     ++ " contributing to possible election timeout *****"
  return $! str''

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
