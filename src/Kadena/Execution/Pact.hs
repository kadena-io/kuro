{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Kadena.Execution.Pact
  (initPactService)
  where

import Control.Concurrent (newMVar,MVar,readMVar,swapMVar)
import Control.Exception (SomeException)
import Control.Exception.Safe (tryAny)
import Control.Monad
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask,ReaderT,runReaderT,reader)
import Data.Aeson as A
import Data.Default
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.String
import Data.Word
import System.Directory (doesFileExist,removeFile)

import Pact.Gas (constGasModel)
import Pact.Interpreter
import Pact.Persist (Persister)
import Pact.Persist.CacheAdapter (initPureCacheWB)
import qualified Pact.Persist.MSSQL as MSSQL
import qualified Pact.Persist.MySQL as MySQL
import qualified Pact.Persist.Pure as Pure
import qualified Pact.Persist.SQLite as SQLite
import qualified Pact.Persist.WriteBehind as WB
import Pact.PersistPactDb (initDbEnv,pactdb)
import Pact.Server.PactService (resultFailure,resultSuccess)
import Pact.Types.Command
import qualified Pact.Types.Crypto as PCrypto
import Pact.Types.Gas (GasEnv(..))
import Pact.Types.Logger (logLog,Logger,Loggers,newLogger)
import Pact.Types.Pretty
import Pact.Types.RPC
import Pact.Types.Runtime
import Pact.Types.Scheme
import Pact.Types.SPV
import Pact.Types.Server (throwCmdEx,userSigsToPactKeySet)

import Kadena.Consensus.Publish
import qualified Kadena.Crypto as KCrypto
import Kadena.Types.Entity hiding (Signer)
import Kadena.Types.Execution
import Kadena.Types.PactDB
import Kadena.Util.Util (linkAsyncBoundTrack)

data PactEnv p = PactEnv {
      _peMode :: ExecutionMode
    , _peDbEnv :: PactDbEnv p
    , _peCommand :: Command (Payload PrivateMeta ParsedCode)
    , _pePublish :: Publish
    , _peEntity :: EntityConfig
    , _peLogger :: Logger
    , _peGasLimit :: GasLimit
    }

type PactM p = ReaderT (PactEnv p) IO

runPact :: PactEnv p -> (PactM p a) -> IO a
runPact e a = runReaderT a e


logInit :: Logger -> String -> IO ()
logInit l = logLog l "INIT"

initPactService :: ExecutionEnv -> Publish ->
                   IO (CommandExecInterface PrivateMeta ParsedCode Hash)
initPactService ExecutionEnv{..} pub = do
  let PactPersistConfig{..} = _eenvPactPersistConfig
      logger = newLogger _eenvExecLoggers "PactService"
      initCI = initCommandInterface _eenvEntityConfig pub logger _eenvExecLoggers
      initWB p db = if _ppcWriteBehind
        then do
          wb <- initPureCacheWB p db  _eenvExecLoggers
          linkAsyncBoundTrack "WriteBehindThread" (WB.runWBService wb)
          initCI WB.persister wb
        else initCI p db
  case _ppcBackend of
    PPBInMemory -> do
      logInit logger "Initializing pure pact"
      initCI Pure.persister Pure.initPureDb
    PPBSQLite conf@SQLite.SQLiteConfig{..} -> do
      dbExists <- doesFileExist _dbFile
      when dbExists $ logInit logger "Deleting Existing Pact DB File" >> removeFile _dbFile
      logInit logger "Initializing SQLite"
      initWB SQLite.persister =<< SQLite.initSQLite conf _eenvExecLoggers
    PPBMSSQL conf connStr -> do
      logInit logger "Initializing MSSQL"
      initWB MSSQL.persister =<< MSSQL.initMSSQL connStr conf _eenvExecLoggers
    PPBMySQL conf -> do
      logInit logger "Initializing MySQL"
      initWB MySQL.persister =<< MySQL.initMySQL conf _eenvExecLoggers

initCommandInterface :: EntityConfig -> Publish -> Logger -> Loggers -> Persister w -> w ->
                        IO (CommandExecInterface PrivateMeta ParsedCode Hash)
initCommandInterface ent pub logger loggers p db = do
  pde <- PactDbEnv pactdb <$> newMVar (initDbEnv loggers p db)
  logInit logger "Creating Pact Schema"
  initSchema pde
  return CommandExecInterface
    { _ceiApplyCmd = \eMode cmd -> applyCmd ent pub logger pde eMode cmd (verifyCommand cmd)
    , _ceiApplyPPCmd = applyCmd ent pub logger pde }




applyCmd :: EntityConfig -> Publish -> Logger -> PactDbEnv p -> ExecutionMode -> Command a ->
            (ProcessedCommand PrivateMeta ParsedCode) -> IO (CommandResult Hash)
applyCmd _ _ _ _ ex cmd (ProcFail s) =
  return $ resultFailure
           Nothing
           (cmdToRequestKey cmd)
           (PactError TxFailure def def . viaShow $ s)
applyCmd ent pub logger dbv exMode _ (ProcSucc cmd) = do
  -- TODO read tx gasLimit from config
  let gasLimit = 10000
  r <- catchesPactError $ runPact (PactEnv exMode dbv cmd pub ent logger gasLimit) $ runPayload cmd
  case r of
    Right cr -> do
      logLog logger "DEBUG" $ "success for requestKey: " ++ show (cmdToRequestKey cmd)
      return cr
    Left e -> do
      logLog logger "ERROR" $ "tx failure for requestKey: " ++ show (cmdToRequestKey cmd) ++ ": " ++ show e
      return $ resultFailure Nothing (cmdToRequestKey cmd) e

-- | Private hardcodes gas rate to 1
gasRate :: Word64
gasRate = 1

-- | Private hardcodes free gas
gasPrice :: GasPrice
gasPrice = 0.0


runPayload :: Command (Payload PrivateMeta ParsedCode) -> PactM p (CommandResult Hash)
runPayload c@Command{..} = case _pPayload _cmdPayload of
    Exec pm -> applyExec c pm (_pSigners _cmdPayload)
    Continuation ym -> applyContinuation c ym (_pSigners _cmdPayload)


applyExec :: Command (Payload PrivateMeta ParsedCode) ->
             ExecMsg ParsedCode -> [Signer] -> PactM p (CommandResult Hash)
applyExec cmd (ExecMsg parsedCode edata) ks = do
  PactEnv {..} <- ask
  when (null (_pcExps parsedCode)) $ throwCmdEx "No expressions found"
  let sigs = userSigsToPactKeySet ks
  let gasEnv = (GasEnv _peGasLimit gasPrice (constGasModel (fromIntegral gasRate)))
      evalEnv = setupEvalEnv _peDbEnv (Just (_elName $ _ecLocal $ _peEntity)) _peMode
                (MsgData sigs edata Nothing (toUntypedHash $ _cmdHash _peCommand))
                initRefStore gasEnv permissiveNamespacePolicy noSPVSupport def
  EvalResult{..} <- liftIO $ evalExec def evalEnv parsedCode
  mapM_ (handlePactExec sigs edata) _erExec
  return $ resultSuccess _erTxId (cmdToRequestKey cmd) _erGas (last _erOutput) _erExec _erLogs

debug :: String -> PactM p ()
debug m = reader _peLogger >>= \l -> liftIO $ logLog l "DEBUG" m


-- | TODO!! The old Kadena pact model keeps the sigs around from the original exec in memory
-- but there is no mechanism for this now. Thus keeping the '_sigs' argument around to reevaluate
-- if this model is sustainable going forward
handlePactExec :: S.Set PublicKey -> Value -> PactExec -> PactM p ()
handlePactExec _sigs edata PactExec{..} = when (_peExecuted == Just True) $ do
  PactEnv{..} <- ask
  let EntityConfig{..} = _peEntity
  publishCont _pePactId 1 False edata

reverseAddy :: EntityName -> Address -> Address
reverseAddy me Address{..} = Address me (S.delete me $ S.insert _aFrom _aTo)

applyContinuation :: Command (Payload PrivateMeta ParsedCode) ->
                     ContMsg -> [Signer] -> PactM p (CommandResult Hash)
applyContinuation cmd cm@ContMsg{..} ks = do
  pe@PactEnv{..} <- ask
  let sigs = userSigsToPactKeySet ks
  let gasEnv = (GasEnv (fromIntegral _peGasLimit) gasPrice (constGasModel (fromIntegral gasRate)))
  let evalEnv = setupEvalEnv _peDbEnv (Just (_elName $ _ecLocal $ _peEntity)) _peMode
                (MsgData sigs Null
                  (Just $ PactStep _cmStep _cmRollback _cmPactId Nothing)
                  (toUntypedHash $ _cmdHash _peCommand))
                initRefStore gasEnv permissiveNamespacePolicy noSPVSupport def
  tryAny (liftIO $ evalContinuation def evalEnv cm) >>=
    either (handleContFailure pe cm)
           (handleContSuccess (cmdToRequestKey cmd) pe cm)


handleContFailure :: PactEnv p -> ContMsg -> SomeException ->
                     PactM p (CommandResult Hash)
handleContFailure pe cm ex = doRollback pe cm (Just True) >> throwM ex

doRollback :: PactEnv p -> ContMsg -> Maybe Bool -> PactM p ()
doRollback PactEnv{..} ContMsg{..} executed = do
  let prevStep = pred _cmStep
      done = prevStep < 0
  unless done $ do
      when (executed == Just True) $ publishCont _cmPactId prevStep True _cmData

handleContSuccess :: RequestKey -> PactEnv p -> ContMsg -> EvalResult ->
                     PactM p (CommandResult Hash)
handleContSuccess rk pe@PactEnv{..} cm@ContMsg{..} er@EvalResult{..} = do
  py@PactExec {..} <- maybe (throwCmdEx "No yield from continuation exec!") return _erExec
  if _cmRollback then
    doRollback pe cm _peExecuted
  else
    doResume pe cm er py
  return $ resultSuccess _erTxId rk _erGas (last _erOutput) _erExec _erLogs

doResume :: PactEnv p -> ContMsg -> EvalResult -> PactExec -> PactM p ()
doResume PactEnv{..} ContMsg{..} EvalResult{..} PactExec{..} = do
  let nextStep = succ _cmStep
      isLast = nextStep >= _peStepCount
  unless isLast $ do
      when (_peExecuted == Just True) $ publishCont _cmPactId nextStep False _cmData

throwPactError :: Doc -> PactM p e
throwPactError = throwM . PactError EvalError def def

publishCont :: PactId -> Int -> Bool -> Value -> PactM p ()
publishCont pactTid step rollback cData = do
  PactEnv{..} <- ask
  let EntityConfig{..} = _peEntity
  when _ecSending $ do
    let me = _elName _ecLocal
        addy = fmap (reverseAddy me) $ _pmAddress  $ _pMeta $ _cmdPayload $ _peCommand
        nonce = fromString $ show (step,rollback)
        (rpc :: PactRPC ()) = Continuation $ ContMsg pactTid step rollback cData Nothing
        (KCrypto.KeyPair kpk ksk) = _ecSigner
    signer <- either (throwPactError . pretty) return $
              PCrypto.importKeyPair (PCrypto.toScheme ED25519)
              (Just $ PCrypto.PubBS $ KCrypto.exportPublic kpk)
              (PCrypto.PrivBS $ KCrypto.exportPrivate ksk)
    cmd <- liftIO $ mkCommand [signer] addy nonce rpc
    debug $ "Sending success continuation for pact: " ++ show rpc
    _rks <- publish _pePublish throwCmdEx $ (buildCmdRpcBS cmd) :| [] -- NonEmpty List
    -- TODO would be good to somehow return all the request keys?
    return ()
