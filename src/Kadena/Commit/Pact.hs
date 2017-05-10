{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Kadena.Commit.Pact

  where

import Control.Concurrent (newMVar,MVar,readMVar,swapMVar)
import Control.Lens (view,makeLenses,set)
import Control.Monad (when,void,join)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask,ReaderT,runReaderT)
import System.Directory (doesFileExist,removeFile)
import Control.Exception.Safe (tryAny)
import Data.Aeson (ToJSON)
import qualified Data.Set as S
import Data.String
import qualified Data.Map.Strict as M

import Pact.Types.Command
import Pact.Types.RPC
import Pact.Types.Logger (logLog,Logger,Loggers,newLogger)
import qualified Pact.Persist.SQLite as SQLite
import qualified Pact.Persist.Pure as Pure
import qualified Pact.Persist.MSSQL as MSSQL
import qualified Pact.Persist.WriteBehind as WB
import Pact.Persist.CacheAdapter (initPureCacheWB)
import Pact.Interpreter (initSchema,initRefStore,PactDbEnv(..),setupEvalEnv,MsgData(..),evalExec,EvalResult(..))
import Pact.Types.Server (throwCmdEx,userSigsToPactKeySet)
import Pact.PersistPactDb (initDbEnv,pactdb)
import Pact.Persist (Persister)
import Pact.Server.PactService (jsonResult)
import Pact.Types.Runtime (PactYield(..),RefStore,TxId(..),PublicKey)


import Kadena.Commit.Types
import Kadena.Consensus.Publish
import Kadena.Types.Config (PactPersistConfig(..),PactPersistBackend(..))
import Kadena.Util.Util (linkAsyncTrack)
import Kadena.Types.Entity

data Pact = Pact
  { _pTxId :: TxId
  , _pPact :: ExecMsg ParsedCode
  , _pSigs :: S.Set PublicKey
  }

data PactState = PactState
  { _psRefStore :: RefStore
  , _psPacts :: M.Map TxId Pact -- TODO need hashable for TxId mebbe
  }
makeLenses ''PactState

data PactEnv p = PactEnv {
      _peConfig :: PactConfig
    , _peMode :: ExecutionMode
    , _peDbEnv :: PactDbEnv p
    , _peState :: MVar PactState
    , _peCommand :: Command (Payload (PactRPC ParsedCode))
    , _pePublish :: Publish
    , _peEntity :: EntityConfig
    , _peLogger :: Logger
    }

type PactM p = ReaderT (PactEnv p) IO

$(makeLenses ''PactEnv)

runPact :: PactEnv p -> (PactM p a) -> IO a
runPact e a = runReaderT a e


logInit :: Logger -> String -> IO ()
logInit l = logLog l "INIT"

initPactService :: CommitEnv -> Publish -> IO (CommandExecInterface (PactRPC ParsedCode))
initPactService CommitEnv{..} pub = do
  let PactPersistConfig{..} = _pactPersistConfig
      logger = newLogger _commitLoggers "PactService"
      initCI = initCommandInterface _entityConfig pub logger _commitLoggers _pactConfig
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

initCommandInterface :: EntityConfig -> Publish -> Logger -> Loggers -> PactConfig -> Persister w -> w ->
                        IO (CommandExecInterface (PactRPC ParsedCode))
initCommandInterface ent pub logger loggers pconf p db = do
  pde <- PactDbEnv pactdb <$> newMVar (initDbEnv loggers p db)
  cmdVar <- newMVar (PactState initRefStore M.empty)
  logInit logger "Creating Pact Schema"
  initSchema pde
  return CommandExecInterface
    { _ceiApplyCmd = \eMode cmd -> applyCmd ent pub logger pconf pde cmdVar eMode cmd (verifyCommand cmd)
    , _ceiApplyPPCmd = applyCmd ent pub logger pconf pde cmdVar }




applyCmd :: EntityConfig -> Publish -> Logger -> PactConfig -> PactDbEnv p -> MVar PactState -> ExecutionMode -> Command a ->
            ProcessedCommand (PactRPC ParsedCode) -> IO CommandResult
applyCmd _ _ _ _ _ _ ex cmd (ProcFail s) = return $ jsonResult ex (cmdToRequestKey cmd) s
applyCmd ent pub logger conf dbv cv exMode _ (ProcSucc cmd) = do
  r <- tryAny $ runPact (PactEnv conf exMode dbv cv cmd pub ent logger) $ runPayload cmd
  case r of
    Right cr -> do
      logLog logger "DEBUG" $ "success for requestKey: " ++ show (cmdToRequestKey cmd)
      return cr
    Left e -> do
      logLog logger "ERROR" $ "tx failure for requestKey: " ++ show (cmdToRequestKey cmd) ++ ": " ++ show e
      return $ jsonResult exMode (cmdToRequestKey cmd) $
               CommandError "Command execution failed" (Just $ show e)

jsonResult' :: ToJSON a => a -> PactM p CommandResult
jsonResult' a = do
  PactEnv{..} <- ask
  return $ jsonResult _peMode (cmdToRequestKey _peCommand) a


runPayload :: Command (Payload (PactRPC ParsedCode)) -> PactM p CommandResult
runPayload Command{..} = case _pPayload _cmdPayload of
    Exec pm -> applyExec pm _cmdSigs
    Continuation ym -> applyContinuation ym _cmdSigs


applyExec :: ExecMsg ParsedCode -> [UserSig] -> PactM p CommandResult
applyExec em@(ExecMsg parsedCode edata) ks = do
  PactEnv {..} <- ask
  when (null (_pcExps parsedCode)) $ throwCmdEx "No expressions found"
  PactState{..} <- liftIO $ readMVar _peState
  let sigs = userSigsToPactKeySet ks
      evalEnv = setupEvalEnv _peDbEnv _peConfig _peMode
                (MsgData (userSigsToPactKeySet ks) edata Nothing) _psRefStore
  EvalResult{..} <- liftIO $ evalExec evalEnv parsedCode
  mp <- join <$> mapM (handleYield em sigs) erYield
  let newState = PactState erRefStore $ case mp of
        Nothing -> _psPacts
        Just (p@Pact{..}) -> M.insert _pTxId p _psPacts
  void $ liftIO $ swapMVar _peState newState
  jsonResult' $ CommandSuccess (last erTerms)

handleYield :: ExecMsg ParsedCode -> S.Set PublicKey -> PactYield -> PactM p (Maybe Pact)
handleYield em sigs PactYield{..} = do
  PactEnv{..} <- ask
  let EntityConfig{..} = _peEntity
  case (_ecSending,_peMode,_pyNextStep) of
    (True,Transactional tid,Just step) -> do
      let me = _elName _ecLocal
          reverseAddy Address{..} = Address me (S.insert _aFrom $ S.delete me _aTo)
          addy = fmap reverseAddy $ _pAddress $ _cmdPayload $ _peCommand
          nonce = fromString $ show tid
          rpc = Continuation $ ContMsg tid step False
          cmd = mkCommand [signer _ecSigner] addy nonce (rpc :: PactRPC ())

      _rks <- publish _pePublish throwCmdEx [(buildCmdRpcBS cmd)]
      liftIO $ logLog _peLogger "DEBUG" $ "Sending continuation for pact: " ++ show tid ++ ", step " ++ show step
      -- TODO, should update the command status with the req keys or something
      return $ Just $ Pact tid em sigs
    (_,_,_) -> return Nothing -- must be sending, transactional, normal yield

applyContinuation :: ContMsg -> [UserSig] -> PactM p CommandResult
applyContinuation _ _ = throwCmdEx "Continuation not supported"
