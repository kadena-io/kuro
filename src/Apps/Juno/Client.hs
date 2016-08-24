{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}

module Apps.Juno.Client
  ( main
  ) where

import Control.Concurrent.MVar
import Control.Concurrent.Lifted (threadDelay)
import qualified Control.Concurrent.Lifted as CL
import Control.Concurrent.Chan.Unagi
import Control.Monad.Reader
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Either ()
import qualified Data.Map as Map
import Text.Read (readMaybe)
import System.IO
import GHC.Int (Int64)
import qualified Data.Text as T
import Data.Aeson

import Juno.Spec.Simple
import Juno.Types.Command
import Juno.Types.Base
import Juno.Types.Message.CMD
import Juno.Command.CommandLayer
import Juno.Command.Types


prompt :: String
prompt = "\ESC[0;31mpact>> \ESC[0m"

promptGreen :: String
promptGreen = "\ESC[0;32mresult>> \ESC[0m"

flushStr :: String -> IO ()
flushStr str = putStr str >> hFlush stdout

readPrompt :: IO String
readPrompt = flushStr prompt >> getLine

showTestingResult :: CommandMVarMap -> Maybe Int64 -> IO ()
showTestingResult s p = do
  threadDelay 1000000 >> do
    (CommandMap _ m) <- readMVar s
    showResult s (fst $ Map.findMax m) p

-- should we poll here till we get a result?
showResult :: CommandMVarMap -> RequestId -> Maybe Int64 -> IO ()
showResult cmdStatusMap' rId Nothing =
  threadDelay 1000 >> do
    (CommandMap _ m) <- readMVar cmdStatusMap'
    case Map.lookup rId m of
      Nothing -> print $ "RequestId [" ++ show rId ++ "] not found."
      Just (CmdApplied (CommandResult x) _) -> putStrLn $ promptGreen ++ BSC.unpack x
      Just _ -> -- not applied yet, loop and wait
        showResult cmdStatusMap' rId Nothing
showResult cmdStatusMap' rId pgm@(Just cnt) =
  threadDelay 1000 >> do
    (CommandMap _ m) <- readMVar cmdStatusMap'
    case Map.lookup rId m of
      Nothing -> print $ "RequestId [" ++ show rId ++ "] not found."
      Just (CmdApplied (CommandResult _x) lat) -> do
        putStrLn $ intervalOfNumerous cnt lat
      Just _ -> -- not applied yet, loop and wait
        showResult cmdStatusMap' rId pgm

--  -> OutChan CommandResult
runREPL :: InChan (RequestId, [(Maybe Alias, CommandEntry)]) -> CommandMVarMap -> Maybe Alias -> MVar Bool -> IO ()
runREPL toCommands' cmdStatusMap' alias' disableTimeouts = loop where
  loop = do
    cmd <- readPrompt
    case cmd of
      "" -> loop
      v | v == "sleep" -> threadDelay 5000000 >> loop
      _ -> do
          cmd' <- return $ BSC.pack cmd
          if take 11 cmd == "batch test:"
          then case readMaybe $ drop 11 cmd of
            Just n -> do
              rId <- liftIO $ setNextCmdRequestId cmdStatusMap'
              writeChan toCommands' (rId, [(alias', CommandEntry cmd')])
              --- this is the tracer round for timing purposes
              putStrLn $ "Sending " ++ show n ++ " batched transactions"
              showTestingResult cmdStatusMap' (Just n)
              loop
            Nothing -> loop
          else if take 10 cmd == "many test:"
          then
            case readMaybe $ drop 10 cmd of
              Just n -> do
                !cmds <- replicateM n
                          (do rid <- setNextCmdRequestId cmdStatusMap'
                              return (rid, [(alias', mkTestPact)]))
                writeList2Chan toCommands' cmds
                --- this is the tracer round for timing purposes
                putStrLn $ "Sending " ++ show n ++ " transactions individually"
                showResult cmdStatusMap' (fst $ last cmds) (Just $ fromIntegral n)
                loop
              Nothing -> loop
          else if cmd == "disable timeout"
            then do
              _ <- swapMVar disableTimeouts True
              t <- readMVar disableTimeouts
              putStrLn $ "disableTimeouts: " ++ show t
              loop
          else if cmd == "enable timeout"
            then do
              _ <- swapMVar disableTimeouts False
              t <- readMVar disableTimeouts
              putStrLn $ "disableTimeouts: " ++ show t
              loop
          else if cmd == "setup"
             then do
               code <- T.pack <$> readFile "demo/demo.pact"
               (ej :: Either String Value) <- eitherDecode <$> liftIO (BSL.readFile "demo/demo.json")
               case ej of
                 Left err -> liftIO (putStrLn $ "ERROR: demo.json file invalid: " ++ show err) >> loop
                 Right j -> do
                   rId <- liftIO $ setNextCmdRequestId cmdStatusMap'
                   writeChan toCommands' (rId, [(alias', mkRPC $ ExecMsg code j)])
                   showResult cmdStatusMap' rId Nothing
                   loop
          else do
            rId <- liftIO $ setNextCmdRequestId cmdStatusMap'
            writeChan toCommands' (rId, [(alias', mkSimplePact $ T.pack cmd)])
            showResult cmdStatusMap' rId Nothing
            loop

intervalOfNumerous :: Int64 -> Int64 -> String
intervalOfNumerous cnt mics = let
  interval' = fromIntegral mics / 1000000
  perSec = ceiling (fromIntegral cnt / interval')
  in "Completed in " ++ show (interval' :: Double) ++ "sec (" ++ show (perSec::Integer) ++ " per sec)"

-- | Runs a 'Raft nt String String mt'.
-- Simple fixes nt to 'HostPort' and mt to 'String'.
main :: IO ()
main = do
  (toCommands, fromCommands) <- newChan
  -- `toResult` is unused. There seem to be API's that use/block on fromResult.
  -- Either we need to kill this channel full stop or `toResult` needs to be used.
  cmdStatusMap' <- initCommandMap
  disableTimeouts <- newMVar False
  let -- getEntry :: (IO et)
      getEntries :: IO (RequestId, [(Maybe Alias, CommandEntry)])
      getEntries = readChan fromCommands
      -- applyFn :: et -> IO rt
      applyFn :: Command -> IO CommandResult
      applyFn _x = return $ CommandResult "Failure"
  void $ CL.fork $ runClient applyFn getEntries cmdStatusMap' disableTimeouts
  threadDelay 100000
  runREPL toCommands cmdStatusMap' Nothing disableTimeouts
