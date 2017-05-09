{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Kadena.Commit.Pact

  where

import Control.Concurrent (newMVar,MVar,readMVar,swapMVar)
import Control.Lens (view)
import Control.Monad (when,void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import System.Directory (doesFileExist,removeFile)
import Control.Exception.Safe (tryAny)
import qualified Data.Set as S

import Pact.Types.Command
  (CommandExecInterface(..), ExecutionMode(..),ParsedCode(..),Command(..),
   ProcessedCommand(..),CommandResult(..),verifyCommand,cmdToRequestKey,
   CommandError(..),Payload(..),Address(..),RequestKey(..),UserSig(..),
   CommandSuccess(..))
import Pact.Types.Logger (logLog,Logger,Loggers,newLogger)
import qualified Pact.Persist.SQLite as SQLite
import qualified Pact.Persist.Pure as Pure
import qualified Pact.Persist.MSSQL as MSSQL
import qualified Pact.Persist.WriteBehind as WB
import Pact.Persist.CacheAdapter (initPureCacheWB)
import Pact.Interpreter (initSchema,initRefStore,PactDbEnv(..),setupEvalEnv,MsgData(..),evalExec,EvalResult(..))
import Pact.Types.RPC (PactRPC(..),PactConfig(..),pactEntity,ExecMsg(..),ContMsg(..))
import Pact.Types.Server (throwCmdEx,userSigsToPactKeySet)
import Pact.PersistPactDb (initDbEnv,pactdb)
import Pact.Persist (Persister)
import Pact.Server.PactService (jsonResult)

import Kadena.Commit.Types
import Kadena.Types.Config (PactPersistConfig(..),PactPersistBackend(..))
import Kadena.Util.Util (linkAsyncTrack)

logInit :: Logger -> String -> IO ()
logInit l = logLog l "INIT"

initPactService :: CommitEnv -> IO (CommandExecInterface (PactRPC ParsedCode))
initPactService CommitEnv{..} = do
  let PactPersistConfig{..} = _pactPersistConfig
      logger = newLogger _commitLoggers "PactService"
      initCI = initCommandInterface logger _commitLoggers _pactConfig
      initWB p db = if _ppcWriteBehind
        then do
          wb <- initPureCacheWB p db  _commitLoggers
          linkAsyncTrack "WriteBehindThread" (WB.runWBService wb)
          initCI WB.persister wb
        else initCI p db
  case _ppcBackend of
    PPBInMemory -> do
      logInit logger "Initializing pure pact"
      initCI Pure.persister Pure.initPureDb
    PPBSQLite conf@SQLite.SQLiteConfig{..} -> do
      dbExists <- doesFileExist dbFile
      when dbExists $ logInit logger "Deleting Existing Pact DB File" >> removeFile dbFile
      logInit logger "Initializing SQLite"
      initWB SQLite.persister =<< SQLite.initSQLite conf _commitLoggers
    PPBMSSQL conf connStr -> do
      logInit logger "Initializing MSSQL"
      initWB MSSQL.persister =<< MSSQL.initMSSQL connStr conf _commitLoggers

initCommandInterface :: Logger -> Loggers -> PactConfig -> Persister w -> w -> IO (CommandExecInterface (PactRPC ParsedCode))
initCommandInterface logger loggers pconf p db = do
  pde <- PactDbEnv pactdb <$> newMVar (initDbEnv loggers p db)
  cmdVar <- newMVar (PactState initRefStore)
  logInit logger "Creating Pact Schema"
  initSchema pde
  return CommandExecInterface
    { _ceiApplyCmd = \eMode cmd -> applyCmd logger pconf pde cmdVar eMode cmd (verifyCommand cmd)
    , _ceiApplyPPCmd = applyCmd logger pconf pde cmdVar }




applyCmd :: Logger -> PactConfig -> PactDbEnv p -> MVar PactState -> ExecutionMode -> Command a ->
            ProcessedCommand (PactRPC ParsedCode) -> IO CommandResult
applyCmd _ _ _ _ ex cmd (ProcFail s) = return $ jsonResult ex (cmdToRequestKey cmd) s
applyCmd logger conf dbv cv exMode _ (ProcSucc cmd) = do
  r <- tryAny $ runPact (PactEnv conf exMode dbv cv) $ runPayload cmd
  case r of
    Right cr -> do
      logLog logger "DEBUG" $ "success for requestKey: " ++ show (cmdToRequestKey cmd)
      return cr
    Left e -> do
      logLog logger "ERROR" $ "tx failure for requestKey: " ++ show (cmdToRequestKey cmd) ++ ": " ++ show e
      return $ jsonResult exMode (cmdToRequestKey cmd) $
               CommandError "Command execution failed" (Just $ show e)


runPayload :: Command (Payload (PactRPC ParsedCode)) -> PactM p CommandResult
runPayload c@Command{..} = do
  let runRpc (Exec pm) = applyExec (cmdToRequestKey c) pm _cmdSigs
      runRpc (Continuation ym) = applyContinuation ym _cmdSigs
      Payload{..} = _cmdPayload
  case _pAddress of
    Just Address{..} -> do
      -- simulate fake blinding if not addressed to this entity
      entName <- view (peConfig . pactEntity)
      mode <- view peMode
      if entName == _aFrom || (entName `S.member` _aTo)
        then runRpc _pPayload
        else return $ jsonResult mode (cmdToRequestKey c) $ CommandError "Private" Nothing
    Nothing -> runRpc _pPayload



applyExec :: RequestKey -> ExecMsg ParsedCode -> [UserSig] -> PactM p CommandResult
applyExec rk (ExecMsg parsedCode edata) ks = do
  PactEnv {..} <- ask
  when (null (_pcExps parsedCode)) $ throwCmdEx "No expressions found"
  (PactState refStore) <- liftIO $ readMVar _peState
  let evalEnv = setupEvalEnv _peDbEnv _peConfig _peMode
                (MsgData (userSigsToPactKeySet ks) edata Nothing) refStore
  pr <- liftIO $ evalExec evalEnv parsedCode
  void $ liftIO $ swapMVar _peState $ PactState (erRefStore pr)
  return $ jsonResult _peMode rk $ CommandSuccess (last (erTerms pr))

applyContinuation :: ContMsg -> [UserSig] -> PactM p CommandResult
applyContinuation _ _ = throwCmdEx "Continuation not supported"
