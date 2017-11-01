{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Kadena.Commit.Pact
  (initPactService)
  where

import Control.Concurrent (newMVar,MVar,readMVar,swapMVar)
import Control.Exception (SomeException)
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask,ReaderT,runReaderT,reader)
import Control.Monad.Catch (MonadThrow,throwM)
import System.Directory (doesFileExist,removeFile)
import Control.Exception.Safe (tryAny)
import Data.Aeson as A
import qualified Data.Set as S
import Data.String
import qualified Data.Map.Strict as M
import qualified Data.HashMap.Strict as HM
import Data.Default

import Pact.Types.Command
import Pact.Types.RPC
import Pact.Types.Logger (logLog,Logger,Loggers,newLogger)
import qualified Pact.Persist.SQLite as SQLite
import qualified Pact.Persist.Pure as Pure
import qualified Pact.Persist.MSSQL as MSSQL
import qualified Pact.Persist.WriteBehind as WB
import Pact.Persist.CacheAdapter (initPureCacheWB)
import Pact.Interpreter
import Pact.Types.Server (throwCmdEx,userSigsToPactKeySet)
import Pact.PersistPactDb (initDbEnv,pactdb)
import Pact.Persist (Persister)
import Pact.Server.PactService (jsonResult)
import Pact.Types.Runtime


import Kadena.Commit.Types
import Kadena.Consensus.Publish
import Kadena.Types.Config (PactPersistConfig(..),PactPersistBackend(..))
import Kadena.Util.Util (linkAsyncTrack)
import Kadena.Types.Entity

data Pact = Pact
  { _pTxId :: TxId
  , _pContinuation :: Term Name
  , _pSigs :: S.Set PublicKey
  , _pStepCount :: Int
  }

data PactState = PactState
  { _psRefStore :: RefStore
  , _psPacts :: M.Map TxId Pact -- TODO need hashable for TxId mebbe
  }

data PactEnv p = PactEnv {
      _peMode :: ExecutionMode
    , _peDbEnv :: PactDbEnv p
    , _peState :: MVar PactState
    , _peCommand :: Command (Payload (PactRPC ParsedCode))
    , _pePublish :: Publish
    , _peEntity :: EntityConfig
    , _peLogger :: Logger
    }

type PactM p = ReaderT (PactEnv p) IO

runPact :: PactEnv p -> (PactM p a) -> IO a
runPact e a = runReaderT a e


logInit :: Logger -> String -> IO ()
logInit l = logLog l "INIT"

initPactService :: CommitEnv -> Publish -> IO (CommandExecInterface (PactRPC ParsedCode))
initPactService CommitEnv{..} pub = do
  let PactPersistConfig{..} = _pactPersistConfig
      logger = newLogger _commitLoggers "PactService"
      initCI = initCommandInterface _entityConfig pub logger _commitLoggers
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

initCommandInterface :: EntityConfig -> Publish -> Logger -> Loggers -> Persister w -> w ->
                        IO (CommandExecInterface (PactRPC ParsedCode))
initCommandInterface ent pub logger loggers p db = do
  pde <- PactDbEnv pactdb <$> newMVar (initDbEnv loggers p db)
  cmdVar <- newMVar (PactState initRefStore M.empty)
  logInit logger "Creating Pact Schema"
  initSchema pde
  return CommandExecInterface
    { _ceiApplyCmd = \eMode cmd -> applyCmd ent pub logger pde cmdVar eMode cmd (verifyCommand cmd)
    , _ceiApplyPPCmd = applyCmd ent pub logger pde cmdVar }




applyCmd :: EntityConfig -> Publish -> Logger -> PactDbEnv p -> MVar PactState -> ExecutionMode -> Command a ->
            ProcessedCommand (PactRPC ParsedCode) -> IO CommandResult
applyCmd _ _ _ _ _ ex cmd (ProcFail s) = return $ jsonResult ex (cmdToRequestKey cmd) s
applyCmd ent pub logger dbv cv exMode _ (ProcSucc cmd) = do
  r <- tryAny $ runPact (PactEnv exMode dbv cv cmd pub ent logger) $ runPayload cmd
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
    Continuation ym -> applyContinuation ym


applyExec :: ExecMsg ParsedCode -> [UserSig] -> PactM p CommandResult
applyExec (ExecMsg parsedCode edata) ks = do
  PactEnv {..} <- ask
  when (null (_pcExps parsedCode)) $ throwCmdEx "No expressions found"
  PactState{..} <- liftIO $ readMVar _peState
  let sigs = userSigsToPactKeySet ks
      evalEnv = setupEvalEnv _peDbEnv (Just (_elName $ _ecLocal $ _peEntity)) _peMode
                (MsgData sigs edata Nothing) _psRefStore
  EvalResult{..} <- liftIO $ evalExec evalEnv parsedCode
  mp <- join <$> mapM (handleYield erInput sigs) erExec
  let newState = PactState erRefStore $ case mp of
        Nothing -> _psPacts
        Just (p@Pact{..}) -> M.insert _pTxId p _psPacts
  void $ liftIO $ swapMVar _peState newState
  jsonResult' $ CommandSuccess (last erOutput)

debug :: String -> PactM p ()
debug m = reader _peLogger >>= \l -> liftIO $ logLog l "DEBUG" m

handleYield :: [Term Name] -> S.Set PublicKey -> PactExec -> PactM p (Maybe Pact)
handleYield em sigs PactExec{..} = do
  PactEnv{..} <- ask
  let EntityConfig{..} = _peEntity
  unless (length em == 1) $
    throwCmdEx $ "handleYield: defpact execution must occur as a single command: " ++ show em
  case _peMode of
    Local -> return Nothing
    Transactional tid -> do
      ry <- mapM encodeResume _peYield
      when _peExecuted $ publishCont tid tid 1 False ry
      return $ Just $ Pact tid (head em) sigs _peStepCount

reverseAddy :: EntityName -> Address -> Address
reverseAddy me Address{..} = Address me (S.delete me $ S.insert _aFrom _aTo)

-- | resumes are JSON encoded similarly to a row: top-level names are encoded as Persistables
encodeResume :: MonadThrow m => Term Name -> m Value
encodeResume (TObject ps _ _) = fmap object $ forM ps $ \p -> case p of
  (TLitString k,v) -> return (k .= toPersistable v)
  (k,_) -> throwCmdEx $ "encodeResume: only string keys supported for yield:" ++ show k
encodeResume t = throwCmdEx $ "encodeResume: expected object type for yield: " ++ show t

decodeResume :: MonadThrow m => Value -> m (Term Name)
decodeResume (Object ps) = fmap (\ps' -> TObject ps' TyAny def) $ forM (HM.toList ps) $ \(k,v) -> case fromJSON v of
  A.Success (p :: Persistable) -> return (toTerm k,toTerm p)
  A.Error r -> throwCmdEx $ "decodeResume: failed to decode value: " ++ show (k,v) ++ ": " ++ r
decodeResume v = throwCmdEx $ "decodeResume: only Object values supported: " ++ show v


applyContinuation :: ContMsg -> PactM p CommandResult
applyContinuation cm@ContMsg{..} = do
  pe@PactEnv{..} <- ask
  case _peMode of
    Local -> throwCmdEx "Local continuation exec not supported"
    Transactional tid -> do
      ps@PactState{..} <- liftIO $ readMVar _peState
      case M.lookup _cmTxId _psPacts of
        Nothing -> throwCmdEx $ "applyContinuation: txid not found: " ++ show _cmTxId
        Just pact@Pact{..} -> do
          when (_cmStep < 0 || _cmStep >= _pStepCount) $ throwCmdEx $ "Invalid step value: " ++ show _cmStep
          res <- mapM decodeResume _cmResume
          let evalEnv = setupEvalEnv _peDbEnv (Just (_elName $ _ecLocal $ _peEntity)) _peMode
                (MsgData _pSigs Null (Just $ PactStep _cmStep _cmRollback (fromString $ show $ _cmTxId) res))
                _psRefStore
          tryAny (liftIO $ evalContinuation evalEnv _pContinuation) >>=
            either (handleContFailure tid pe cm ps) (handleContSuccess tid pe cm ps pact)


handleContFailure :: TxId -> PactEnv p -> ContMsg -> PactState -> SomeException -> PactM p CommandResult
handleContFailure tid pe cm ps ex = doRollback tid pe cm ps True >> throwM ex

doRollback :: TxId -> PactEnv p -> ContMsg -> PactState -> Bool -> PactM p ()
doRollback tid PactEnv{..} ContMsg{..} PactState{..} executed = do
  let prevStep = pred _cmStep
      done = prevStep < 0
  if done
    then do
    debug $ "handleContFailure: reaping pact: " ++ show _cmTxId
    void $ liftIO $ swapMVar _peState $ PactState _psRefStore $ M.delete _cmTxId _psPacts
    else when executed $ publishCont _cmTxId tid prevStep True Nothing

handleContSuccess :: TxId -> PactEnv p -> ContMsg -> PactState -> Pact -> EvalResult -> PactM p CommandResult
handleContSuccess tid pe@PactEnv{..} cm@ContMsg{..} ps@PactState{..} p@Pact{..} er@EvalResult{..} = do
  py@PactExec {..} <- maybe (throwCmdEx "No yield from continuation exec!") return erExec
  if _cmRollback then
    doRollback tid pe cm ps _peExecuted
  else
    doResume tid pe cm ps p er py
  jsonResult' $ CommandSuccess (last erOutput)

doResume :: TxId -> PactEnv p -> ContMsg -> PactState -> Pact -> EvalResult -> PactExec -> PactM p ()
doResume tid PactEnv{..} ContMsg{..} PactState{..} Pact{..} EvalResult{..} PactExec{..} = do
  let nextStep = succ _cmStep
      isLast = nextStep >= _pStepCount
      updateState pacts = void $ liftIO $ swapMVar _peState (PactState erRefStore pacts)
  if isLast
    then do
      debug $ "handleContSuccess: reaping pact [disabled]: " ++ show _cmTxId
      -- updateState $ M.delete _cmTxId _psPacts
    else do
      ry <- mapM encodeResume _peYield
      when _peExecuted $ publishCont _cmTxId tid nextStep False ry
      updateState _psPacts

publishCont :: TxId -> TxId -> Int -> Bool -> Maybe Value -> PactM p ()
publishCont pactTid tid step rollback resume = do
  PactEnv{..} <- ask
  let EntityConfig{..} = _peEntity
  when _ecSending $ do
    let me = _elName _ecLocal
        addy = fmap (reverseAddy me) $ _pAddress $ _cmdPayload $ _peCommand
        nonce = fromString $ show tid
        (rpc :: PactRPC ()) = Continuation $ ContMsg pactTid step rollback resume
        cmd = mkCommand [signer _ecSigner] addy nonce rpc
    debug $ "Sending success continuation for pact: " ++ show rpc
    _rks <- publish _pePublish throwCmdEx [(buildCmdRpcBS cmd)]
    -- TODO would be good to somehow return all the request keys?
    return ()
