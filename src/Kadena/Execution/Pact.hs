{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Execution.Pact
  ( PactEnv(..), peMode, peDbEnv, peCommand, peLogger, pePublish ,peEntity, peGasLimit, peModuleCache
  , initPactService )
  where

import Control.Concurrent (newMVar)
import Control.Exception (SomeException)
import Control.Exception.Safe (tryAny)
import Control.Lens
import Control.Monad
import Control.Monad.Catch (catches, Handler(..), MonadCatch, throwM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask, ReaderT, runReaderT, reader)
import Crypto.Noise as Dh (convert)
import qualified Crypto.Noise.DH as Dh
import Data.Aeson as A
import Data.Default
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.Set as S
import Data.String
import Data.Tuple.Strict (T2(..))
import Data.Word
import System.Directory (doesFileExist,removeFile)

import Pact.Gas (constGasModel)
import Pact.Interpreter
import Pact.Persist (Persister)
import Pact.Persist.CacheAdapter (initPureCacheWB)
import qualified Pact.Interpreter as P
import qualified Pact.Persist.MSSQL as MSSQL
import qualified Pact.Persist.MySQL as MySQL
import qualified Pact.Persist.Pure as Pure
import qualified Pact.Persist.SQLite as SQLite
import qualified Pact.Persist.WriteBehind as WB
import Pact.PersistPactDb (initDbEnv,pactdb)
import Pact.Server.PactService (resultFailure,resultSuccess)
import Pact.Types.ChainMeta
import qualified Pact.Types.Command as Pact (Command(..), CommandResult(..))
import Pact.Types.Command
import qualified Pact.Types.Crypto as PCrypto
import Pact.Types.Gas (GasEnv(..), GasLimit)
import Pact.Types.Logger (logLog,Logger,Loggers,newLogger)
import Pact.Types.Persistence
import Pact.Types.Pretty
import Pact.Types.RPC
import qualified Pact.Types.Runtime as P (PublicKey)
import Pact.Types.Runtime hiding (catchesPactError)
import Pact.Types.Scheme
import Pact.Types.SPV
import Pact.Types.Server (throwCmdEx,userSigsToPactKeySet)

import Kadena.Consensus.Publish
import Kadena.Types.Entity
import Kadena.Types.Execution
import Kadena.Types.PactDB
import Kadena.Util.Util (linkAsyncBoundTrack)

data PactEnv p = PactEnv {
      _peMode :: ExecutionMode
    , _peDbEnv :: PactDbEnv p
    , _peCommand :: Pact.Command (Payload PrivateMeta ParsedCode)
    , _pePublish :: Publish
    , _peEntity :: EntityConfig
    , _peLogger :: Logger
    , _peGasLimit :: GasLimit
    , _peModuleCache ::  ModuleCache
    }
makeLenses ''PactEnv

type PactM p = ReaderT (PactEnv p) IO

runPact :: PactEnv p -> (PactM p a) -> IO a
runPact e a = runReaderT a e

logInit :: Logger -> String -> IO ()
logInit l = logLog l "INIT"

initPactService
  :: ExecutionEnv
  -> Publish
  -> IO (KCommandExecInterface PrivateMeta ParsedCode Hash)
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

initCommandInterface
  :: EntityConfig
  -> Publish
  -> Logger
  -> Loggers
  -> Persister w
  -> w
  -> IO (KCommandExecInterface PrivateMeta ParsedCode Hash)
initCommandInterface ent pub logger loggers p db = do
  pde <- PactDbEnv pactdb <$> newMVar (initDbEnv loggers p db)
  logInit logger "Creating Pact Schema"
  initSchema pde
  return KCommandExecInterface
    { _kceiApplyCmd = \eMode modCache cmd
        -> applyCmd ent pub logger pde eMode modCache cmd (verifyCommand cmd)
    , _kceiApplyPPCmd = applyCmd ent pub logger pde}

applyCmd
  :: EntityConfig
  -> Publish
  -> Logger
  -> PactDbEnv p
  -> ExecutionMode
  -> ModuleCache
  -> Pact.Command a
  -> (ProcessedCommand PrivateMeta ParsedCode)
  -> IO (T2 (Pact.CommandResult Hash) ModuleCache)
applyCmd _ _ _ _ _ moduleCache cmd (ProcFail s) =
  return $ (T2 (resultFailure
                   Nothing
                   (cmdToRequestKey cmd)
                   (PactError TxFailure def def . viaShow $ s))
           moduleCache) -- Not updating moduleCache on failure

applyCmd ent pub logger dbv exMode moduleCache _ (ProcSucc cmd) = do
  -- TODO read tx gasLimit from config
  let gasLimit = 10000
  r <- catchesPactError $
    runPact PactEnv { _peMode = exMode
                    , _peDbEnv = dbv
                    , _peCommand = cmd
                    , _pePublish = pub
                    , _peEntity = ent
                    , _peLogger = logger
                    , _peGasLimit = gasLimit
                    , _peModuleCache = moduleCache}
            $ runPayload cmd
  case r of
    Right (T2 cr moduleCache') -> do
      logLog logger "DEBUG" $ "success for requestKey: " ++ show (cmdToRequestKey cmd)
      return (T2 cr moduleCache')
    Left e -> do
      logLog logger "ERROR" $ "tx failure for requestKey: " ++ show (cmdToRequestKey cmd)
                            ++ ": " ++ show e
      return $ T2 (resultFailure Nothing (cmdToRequestKey cmd) e) moduleCache
      -- Not updating moduleCache in case of failure

catchesPactError
  :: (MonadCatch m)
  => m (T2 (Pact.CommandResult Hash) ModuleCache)
  -> m (Either PactError (T2 (Pact.CommandResult Hash) ModuleCache))
catchesPactError action =
  catches (Right <$> action)
  [ Handler (\(e :: PactError) -> return $ Left e)
   ,Handler (\(e :: SomeException) -> return $ Left . PactError EvalError def def . viaShow $ e)
  ]

-- | Private hardcodes gas rate to 1
gasRate :: Word64
gasRate = 1

-- | Private hardcodes free gas
gasPrice :: GasPrice
gasPrice = 0.0

runPayload
  :: Pact.Command (Payload PrivateMeta ParsedCode)
  -> PactM p (T2 (Pact.CommandResult Hash) ModuleCache)
runPayload c@Pact.Command{..} = case _pPayload _cmdPayload of
    Exec pm -> applyExec c pm (_pSigners _cmdPayload)
    Continuation ym -> do
      cr <- applyContinuation c ym (_pSigners _cmdPayload)
      moduleCache <- view peModuleCache
      return (T2 cr moduleCache) -- no module cache updates for continuations


applyExec :: Pact.Command (Payload PrivateMeta ParsedCode) ->
             ExecMsg ParsedCode -> [Signer] -> PactM p (T2 (Pact.CommandResult Hash) ModuleCache)
applyExec cmd (ExecMsg parsedCode edata) ks = do
  PactEnv {..} <- ask
  when (null (_pcExps parsedCode)) $ throwCmdEx "No expressions found"
  let sigs = userSigsToPactKeySet ks
  let gasEnv = (GasEnv _peGasLimit gasPrice (constGasModel (fromIntegral gasRate)))
      evalEnv = setupEvalEnv _peDbEnv (Just (_elName $ _ecLocal $ _peEntity)) _peMode
                (MsgData edata Nothing (toUntypedHash $ _cmdHash _peCommand))
                initRefStore gasEnv permissiveNamespacePolicy noSPVSupport def
  EvalResult{..} <- liftIO $ evalExec ks (mkStateInterpreter _peModuleCache) evalEnv parsedCode
  mapM_ (handlePactExec sigs edata) _erExec
  return $ T2
    (resultSuccess _erTxId (cmdToRequestKey cmd) _erGas (last _erOutput) _erExec _erLogs)
    _erLoadedModules

mkStateInterpreter :: ModuleCache -> Interpreter p
mkStateInterpreter moduleCache = initStateInterpreter $ set (evalRefs . rsLoadedModules) moduleCache def

initStateInterpreter :: EvalState -> Interpreter p
initStateInterpreter s = P.defaultInterpreterState (const s)

debug :: String -> PactM p ()
debug m = reader _peLogger >>= \l -> liftIO $ logLog l "DEBUG" m

-- | TODO!! The old Kadena pact model keeps the sigs around from the original exec in memory
-- but there is no mechanism for this now. Thus keeping the '_sigs' argument around to reevaluate
-- if this model is sustainable going forward
handlePactExec :: S.Set P.PublicKey -> Value -> PactExec -> PactM p ()
handlePactExec _sigs edata PactExec{..} = when (_peExecuted == Just True) $ do
  PactEnv{..} <- ask
  let EntityConfig{..} = _peEntity
  publishCont _pePactId 1 False edata

reverseAddy :: EntityName -> Address -> Address
reverseAddy me Address{..} = Address me (S.delete me $ S.insert _aFrom _aTo)

applyContinuation
  :: Pact.Command (Payload PrivateMeta ParsedCode)
  -> ContMsg
  -> [Signer]
  -> PactM p (Pact.CommandResult Hash)
applyContinuation cmd cm@ContMsg{..} ks = do
  pe@PactEnv{..} <- ask
  let gasEnv = (GasEnv (fromIntegral _peGasLimit) gasPrice (constGasModel (fromIntegral gasRate)))
  let evalEnv = setupEvalEnv _peDbEnv (Just (_elName $ _ecLocal $ _peEntity)) _peMode
                (MsgData Null
                  (Just $ PactStep _cmStep _cmRollback _cmPactId Nothing)
                  (toUntypedHash $ _cmdHash _peCommand))
                initRefStore gasEnv permissiveNamespacePolicy noSPVSupport def
  ei <- tryAny (liftIO $ evalContinuation ks (mkStateInterpreter _peModuleCache) evalEnv cm)
  either (handleContFailure pe cm)
         (handleContSuccess (cmdToRequestKey cmd) pe cm)
         ei

handleContFailure
  :: PactEnv p
  -> ContMsg
  -> SomeException
  -> PactM p (Pact.CommandResult Hash)
handleContFailure pe cm ex = do
  doRollback pe cm (Just True)
  throwM ex

doRollback :: PactEnv p -> ContMsg -> Maybe Bool -> PactM p ()
doRollback PactEnv{..} ContMsg{..} executed = do
  let prevStep = pred _cmStep
      done = prevStep < 0
  unless done $ do
      when (executed == Just True) $ publishCont _cmPactId prevStep True _cmData

handleContSuccess
  :: RequestKey
  -> PactEnv p
  -> ContMsg
  -> EvalResult
  -> PactM p (Pact.CommandResult Hash)
handleContSuccess rk pe@PactEnv{..} cm@ContMsg{..} er@EvalResult{..} = do
  py@PactExec {..} <- maybe (throwCmdEx "No yield from continuation exec!") return _erExec
  if _cmRollback
    then doRollback pe cm _peExecuted
    else doResume pe cm er py
  return (resultSuccess _erTxId rk _erGas (last _erOutput) _erExec _erLogs)

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
        (EntityKeyPair ksk kpk) = _ecSigner
    signer <- either (throwPactError . pretty) return $
      PCrypto.importKeyPair
        (PCrypto.toScheme ED25519)
        (Just $ PCrypto.PubBS $ Dh.convert (Dh.dhPubToBytes (epPublicKey kpk)))
        (PCrypto.PrivBS $ Dh.convert (Dh.dhSecToBytes (esSecretKey ksk)))
    cmd <- liftIO $ mkCommand [(signer, [])] addy nonce Nothing rpc
    debug $ "Sending success continuation for pact: " ++ show rpc
    _rks <- publish _pePublish throwCmdEx $ (buildCmdRpcBS cmd) :| [] -- NonEmpty List
    -- TODO would be good to somehow return all the request keys?
    return ()
