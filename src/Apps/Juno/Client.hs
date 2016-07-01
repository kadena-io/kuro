{-# LANGUAGE OverloadedStrings #-}

module Apps.Juno.Client
  ( main
  ) where

import Control.Concurrent.MVar
import Control.Concurrent.Lifted (threadDelay)
import qualified Control.Concurrent.Lifted as CL
import Control.Concurrent.Chan.Unagi
import Control.Monad.Reader
import qualified Data.ByteString.Char8 as BSC
import Data.Either ()
import qualified Data.Map as Map
import Text.Read (readMaybe)
import System.IO
import GHC.Int (Int64)

import Juno.Spec.Simple
import Juno.Types

import Apps.Juno.Parser

prompt :: String
prompt = "\ESC[0;31mhopper>> \ESC[0m"

promptGreen :: String
promptGreen = "\ESC[0;32mresult>> \ESC[0m"

flushStr :: String -> IO ()
flushStr str = putStr str >> hFlush stdout

readPrompt :: IO String
readPrompt = flushStr prompt >> getLine

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
runREPL :: InChan (RequestId, [(Maybe Alias, CommandEntry)]) -> CommandMVarMap -> Maybe Alias -> IO ()
runREPL toCommands' cmdStatusMap' alias' = do
  cmd <- readPrompt
  case cmd of
    "" -> runREPL toCommands' cmdStatusMap' alias'
    v | v == "sleep" -> threadDelay 5000000 >> runREPL toCommands' cmdStatusMap' alias'
    _ -> do
      cmd' <- return $ BSC.pack cmd
      case readAlias cmd' of
        Just alias@(Just a') -> do
          putStrLn $ "Encrypting all future commands for: " ++ show (unAlias a')
          runREPL toCommands' cmdStatusMap' alias
        Just Nothing -> do
          putStrLn "Encryption disabled: all future commands will be public"
          runREPL toCommands' cmdStatusMap' Nothing
        Nothing -> do
          if take 11 cmd == "batch test:"
          then case readMaybe $ drop 11 cmd of
            Just n -> do
              rId <- liftIO $ setNextCmdRequestId cmdStatusMap'
              writeChan toCommands' (rId, [(alias', CommandEntry cmd')])
              --- this is the tracer round for timing purposes
              putStrLn $ "Sending " ++ show n ++ " 'transfer(Acct1->Acct2, 1%1)' transactions batched"
              showResult cmdStatusMap' (rId + RequestId n) (Just n)
              runREPL toCommands' cmdStatusMap' alias'
            Nothing -> runREPL toCommands' cmdStatusMap' alias'
          else if take 10 cmd == "many test:"
          then do
            case readMaybe $ drop 10 cmd of
              Just n -> do
                cmds <- replicateM n
                          (do rid <- setNextCmdRequestId cmdStatusMap'; return (rid, [(alias', CommandEntry "transfer(Acct1->Acct2, 1%1)")]))
                writeList2Chan toCommands' cmds
                --- this is the tracer round for timing purposes
                putStrLn $ "Sending " ++ show n ++ " 'transfer(Acct1->Acct2, 1%1)' transactions individually"
                showResult cmdStatusMap' (fst $ last cmds) (Just $ fromIntegral n)
                runREPL toCommands' cmdStatusMap' alias'
              Nothing -> runREPL toCommands' cmdStatusMap' alias'
          else
            case readHopper cmd' of
              Left err -> putStrLn cmd >> putStrLn err >> runREPL toCommands' cmdStatusMap' alias'
              Right _ -> do
                rId <- liftIO $ setNextCmdRequestId cmdStatusMap'
                writeChan toCommands' (rId, [(alias', CommandEntry cmd')])
                showResult cmdStatusMap' rId Nothing
                runREPL toCommands' cmdStatusMap' alias'

intervalOfNumerous :: Int64 -> Int64 -> String
intervalOfNumerous cnt mics = let
  interval = fromIntegral mics / 1000000
  perSec = ceiling (fromIntegral cnt / interval)
  in "Completed in " ++ show (interval :: Double) ++ "sec (" ++ show (perSec::Integer) ++ " per sec)"

-- | Runs a 'Raft nt String String mt'.
-- Simple fixes nt to 'HostPort' and mt to 'String'.
main :: IO ()
main = do
  (toCommands, fromCommands) <- newChan
  -- `toResult` is unused. There seem to be API's that use/block on fromResult.
  -- Either we need to kill this channel full stop or `toResult` needs to be used.
  cmdStatusMap' <- initCommandMap
  let -- getEntry :: (IO et)
      getEntries :: IO (RequestId, [(Maybe Alias, CommandEntry)])
      getEntries = readChan fromCommands
      -- applyFn :: et -> IO rt
      applyFn :: Command -> IO CommandResult
      applyFn _x = return $ CommandResult "Failure"
  void $ CL.fork $ runClient applyFn getEntries cmdStatusMap'
  threadDelay 100000
  runREPL toCommands cmdStatusMap' Nothing
