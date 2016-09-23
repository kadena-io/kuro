{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

module Kadena.Command.CommandLayer where

import Control.Concurrent
import Data.Default
import Data.Aeson as A
import Data.ByteString (ByteString)
import Data.ByteString.Lazy (toStrict,fromStrict)
import qualified Data.ByteString.Base16 as B16
import Data.Serialize as SZ hiding (get,put)
import Control.Monad.State
import Control.Monad.Reader
import Control.Exception.Safe
import Control.Applicative
import Control.Lens hiding ((.=))
import qualified Data.Set as S
import Data.Maybe
import qualified Text.Trifecta as TF
import qualified Data.Attoparsec.Text as AP
import Control.Monad.Except
import Data.Text (Text,unpack)
import Prelude hiding (log,exp)
import qualified Data.HashMap.Strict as HM
import Text.PrettyPrint.ANSI.Leijen (renderCompact,displayS)

import Pact.Types hiding (PublicKey)
import qualified Pact.Types as Pact
import Pact.Pure
import Pact.Eval
import Pact.Compile as Pact
import Pact.Native

import Kadena.Types.Log
import Kadena.Types.Base hiding (Term)
import Kadena.Types.Command
import Kadena.Types.Message hiding (RPC)
import Kadena.Command.Types
import Kadena.Types.Config
import Kadena.Types.Service.Commit (ApplyFn)

initCommandLayer :: CommandConfig -> IO (ApplyFn,ApplyLocal)
initCommandLayer config = do
  (Right nds,_) <- runEval undefined undefined nativeDefs
  mv <- newMVar (CommandState def (RefStore nds HM.empty))
  return (applyTransactional config mv,applyLocal config mv)


applyTransactional :: CommandConfig -> MVar CommandState -> LogEntry -> IO CommandResult
applyTransactional config mv le = do
  let logIndex = _leLogIndex le
  s <- takeMVar mv
  r <- tryAny (runCommand
               (CommandEnv config (Transactional $ fromIntegral logIndex))
               s
               (applyLogEntry le))
  case r of
    Right (cr,s') -> do
           putMVar mv s'
           return cr
    Left e -> do
        putMVar mv s
        return $ jsonResult $
               CommandError "Transaction execution failed" (Just $ show e)

jsonResult :: ToJSON a => a -> CommandResult
jsonResult = CommandResult . toStrict . A.encode

applyLocal :: CommandConfig -> MVar CommandState -> ByteString -> IO CommandResult
applyLocal config mv bs = do
  s <- readMVar mv
  r <- tryAny (runCommand
               (CommandEnv config Local)
               s
               (applyPactMessage bs))
  case r of
    Right (cr,_) -> return cr
    Left e ->
        return $ jsonResult $
               CommandError "Local execution failed" (Just $ show e)

applyLogEntry :: LogEntry -> CommandM CommandResult
applyLogEntry e = do
    let
        cmd = _leCommand e
        bs = unCommandEntry $ _cmdEntry cmd
    cmsg :: CommandMessage <- either (throwCmdEx . ("applyLogEntry: deserialize failed: " ++ ) . show) return $
            SZ.decode bs
    case cmsg of
      PublicMessage m -> do
                    pk <- case firstOf (cmdProvenance.pDig.digPubkey) cmd of
                            Nothing -> return [] -- really an error but this is still toy code
                            Just k -> return [Pact.PublicKey (B16.encode $ exportPublic k)]
                    applyRPC pk m
      PrivateMessage ct mt m -> applyPrivate ct mt m

applyPactMessage :: ByteString -> CommandM CommandResult
applyPactMessage m = do
  pmsg <- either (throwCmdEx . ("applyPactMessage: deserialize failed: " ++ ) . show) return $
          SZ.decode m
  pk <- validateSig pmsg
  applyRPC [pk] (_pmPayload pmsg)

applyRPC :: [Pact.PublicKey] -> ByteString -> CommandM CommandResult
applyRPC ks m =
  case A.eitherDecode (fromStrict m) of
      Right (Exec pm) -> applyExec pm ks
      Right (Continuation ym) -> applyContinuation ym ks
      Right (Multisig mm) -> applyMultisig mm ks
      Left err -> throwCmdEx $ "RPC deserialize failed: " ++ show err ++ show m

validateSig :: PactMessage -> CommandM Pact.PublicKey
validateSig (PactMessage payload key sig)
    | valid payload key sig = return (Pact.PublicKey (exportPublic key)) -- TODO turn off with compile flags?
    | otherwise = throwCmdEx "Signature verification failure"

parse :: ExecutionMode -> Text -> CommandM [Exp]
parse (Transactional _) code =
    case AP.parseOnly Pact.exprs code of
      Right s -> return s
      Left e -> throwCmdEx $ "Pact parse failed: " ++ e
parse Local code =
    case TF.parseString Pact.exprs mempty (unpack code) of
      TF.Success s -> return s
      TF.Failure f -> throwCmdEx $ "Pact parse failed: " ++
                      displayS (renderCompact (TF._errDoc f)) ""


applyExec :: ExecMsg -> [Pact.PublicKey] -> CommandM CommandResult
applyExec (ExecMsg code edata) ks = do
  env <- ask
  let mode = _ceMode env
  exps <- parse (_ceMode env) code
  when (null exps) $ throwCmdEx "No expressions found"
  terms <- forM exps $ \exp -> case compile exp of
            Right r -> return r
            Left (i,e) -> throwCmdEx $ "Pact compile failed: " ++ show i ++ ": " ++ show e
  (CommandState pureState refStore) <- get
  mv <- liftIO $ newMVar pureState
  let evalEnv = EvalEnv {
                  _eeRefStore = refStore
                , _eeMsgSigs = S.fromList ks
                , _eeMsgBody = edata
                , _eeTxId = fromMaybe 0 $ firstOf emTxId mode
                , _eeEntity = view (ceConfig.ccEntity.entName) env
                , _eePactStep = Nothing
                , _eePactDb = puredb
                , _eePactDbVar = mv
                }
  (r,rEvalState') <- liftIO $ runEval def evalEnv (execTerms mode terms)
  case r of
    Right t -> do
           when (mode /= Local) $ do
                 pureState' <- liftIO $ readMVar mv
                 put (CommandState pureState' $
                     over rsModules (HM.union (HM.fromList (_rsNew (_evalRefs rEvalState')))) refStore)
           return $ jsonResult $ CommandSuccess t -- TODO Yield handling
    Left e -> throwCmdEx $ "Exec failed: " ++ show e


execTerms :: ExecutionMode -> [Term Name] -> Eval PureState (Term Name)
execTerms mode terms = do
  evalBeginTx
  er <- catchError
        (last <$> mapM eval terms)
        (\e -> evalRollbackTx >> throwError e)
  case mode of
    Transactional _ -> void evalCommitTx
    Local -> evalRollbackTx
  return er


applyContinuation :: ContMsg -> [Pact.PublicKey] -> CommandM CommandResult
applyContinuation _ _ = throwCmdEx "Continuation not supported"

applyMultisig :: MultisigMsg -> [Pact.PublicKey] -> CommandM CommandResult
applyMultisig _ _ = throwCmdEx "Multisig not supported"

applyPrivate :: SessionCipherType -> MessageTags -> ByteString -> CommandM a
applyPrivate _ _ _ = throwCmdEx "Private messages not supported"

mkPactMessage :: PublicKey -> PrivateKey -> PactRPC -> PactMessage
mkPactMessage pk sk rpc = PactMessage bs pk (sign bs sk pk)
    where bs = toStrict $ A.encode rpc

_pk :: PublicKey
_pk = fromJust $ importPublic $ fst $ B16.decode "06f1ade90e5637a3392dbd7aa01486d4ac597dbf7707dfb12f94f9b9d69fcf0f"
_sk :: PrivateKey
_sk = fromJust $ importPrivate $ fst $ B16.decode "2ca45751578698d73759b44feeea38391cd4136bb8265cd3a36f488cbadf8eb7"

_config :: CommandConfig
_config = CommandConfig (EntityInfo "me")

_localRPC :: ToRPC a => a -> IO ByteString
_localRPC rpc = do
  (_,runl) <- initCommandLayer _config
  let p = mkPactMessage _pk _sk (toRPC rpc)
  unCommandResult <$> runl (SZ.encode p)

_publicRPC :: ToRPC a => a -> LogIndex -> IO ByteString
_publicRPC rpc li = do
  (runt,_) <- initCommandLayer _config
  let p = mkPactMessage _pk _sk (toRPC rpc)
      pm = PublicMessage (SZ.encode p)
      le = LogEntry 0 li (Command (CommandEntry (SZ.encode pm))
                          (NodeId "" 0 "" (Alias ""))
                          0 Valid NewMsg) ""
  unCommandResult <$> runt le

mkRPC :: ToRPC a => a ->  CommandEntry
mkRPC = CommandEntry . SZ.encode . PublicMessage . toStrict . A.encode . A.toJSON . toRPC

mkSimplePact :: Text -> CommandEntry
mkSimplePact = mkRPC . (`ExecMsg` A.Null)

mkTestPact :: CommandEntry
mkTestPact = mkSimplePact "(demo.transfer \"Acct1\" \"Acct2\" 1.0)"
