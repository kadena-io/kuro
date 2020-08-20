{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE CPP #-}

module Pact.Persist.CacheAdapter
  ( initTestPureSQLite
  , CacheAdapter(..), caPersister, caState, committedKeys, tempKeys
  , CacheContext(..), ccWriteBehind, ccAsync
  , regressPureSQLite
  , initPureCacheWB
  , runDemoWB
#ifdef DB_ADAPTERS
  , initTestPureMySQL
#endif
  ) where

import qualified Data.Set as S
import qualified Data.Map.Strict as M
import Control.Lens hiding ((.=))
import Control.Arrow
import Data.Default

import Control.Concurrent.Chan
import Control.Concurrent.MVar
import System.Directory
import Control.Monad
import Control.Concurrent.Async (async, link, Async)
import Control.Exception (throwIO)

import Data.Aeson

import Pact.Persist
import Pact.Persist.WriteBehind hiding (persister,logger)
import qualified Pact.Persist.WriteBehind as WB
import qualified Pact.Persist.Pure as Pure
import qualified Pact.Persist.SQLite as SQLite
#ifdef DB_ADAPTERS
import qualified Pact.Persist.MySQL as MySQL
#endif
import Pact.PersistPactDb
import qualified Data.Attoparsec.Text as AP

import Pact.Gas (constGasModel)
import Pact.Interpreter
import Pact.Types.Command
import Pact.Types.Hash
import qualified Data.Text as T
import Pact.Parse
import Pact.Types.Logger
import Pact.Types.Gas (GasEnv(..))
import Pact.Types.Persistence
import Pact.Types.Runtime (_eeRefStore, permissiveNamespacePolicy)
import Pact.Types.SPV

import Pact.PersistPactDb.Regression

newtype CacheKeys k = CacheKeys { _cacheKeys :: M.Map (Table k) (S.Set k) }
instance Default (CacheKeys k) where def = CacheKeys M.empty

data KeysDb = KeysDb {
  _dataKeys :: !(CacheKeys DataKey),
  _txKeys :: !(CacheKeys TxKey)
  }
instance Default KeysDb where def = KeysDb def def

data CacheAdapter p = CacheAdapter {
  _caPersister :: Persister p,
  _caState :: p,
  _committedKeys :: KeysDb,
  _tempKeys :: KeysDb
  }

-- | Data type allowing the parent thread to tell the database thread to exit, and then
--   wait for the exit to occur
data CacheContext c w = CacheContext
  { _ccWriteBehind :: WB c w
  , _ccAsync :: Async ()
  }

makeLenses ''CacheKeys
makeLenses ''KeysDb
makeLenses ''CacheAdapter
makeLenses ''CacheContext

keysDb :: Table k -> Lens' KeysDb (CacheKeys k)
keysDb DataTable {} = dataKeys
keysDb TxTable {} = txKeys

adapt :: (Persister p -> Persist p a) -> Persist (CacheAdapter p) a
adapt f s@CacheAdapter{..} = do
  (p',r) <- f _caPersister _caState
  return (s { _caState = p'},r)
{-# INLINE adapt #-}

persister :: Persister (CacheAdapter p)
persister = Persister {

  createTable = \t s -> adapt (\p -> createTable p t) s
  ,
  beginTx = \t s -> first resetTemp <$> adapt (\p -> beginTx p t) s
  ,
  commitTx = \s -> first commitTemp <$> adapt commitTx s
  ,
  rollbackTx = \s -> first resetTemp <$> adapt rollbackTx s
  ,
  queryKeys = \t kq s -> adapt (\p -> queryKeys p t kq) s
  ,
  query = \t kq s -> adapt (\p -> query p t kq) s
  ,
  readValue = \t k s -> adapt (\p -> readValue p t k) s
  ,
  writeValue = \t wt k v s -> first (trackKey t k) <$> adapt (\p -> writeValue p t wt k v) s
  ,
  refreshConn = \s -> adapt refreshConn s
  }

resetTemp :: CacheAdapter p -> CacheAdapter p
resetTemp p@CacheAdapter {..} = p { _tempKeys = _committedKeys }

commitTemp :: CacheAdapter p -> CacheAdapter p
commitTemp p@CacheAdapter {..} = p { _committedKeys = _tempKeys }

trackKey :: PactDbKey k => Table k -> k -> CacheAdapter p -> CacheAdapter p
trackKey t k = over (tempKeys . keysDb t . cacheKeys) $ M.insertWith S.union t (S.singleton k)

-- | Make cache access for adapter. CacheAccess provided is expected
-- to return Left () if the table doesn't exist, otherwise Right result.
initCacheAccess :: CacheAccess p -> CacheAccess (CacheAdapter p)
initCacheAccess ca = CacheAccess {
  cacheRead = \t k s -> adapt (\_ -> cacheRead ca t k) s >>= \r -> case r of
      (_,Right Nothing) -> case firstOf (tempKeys . keysDb t . cacheKeys . ix t) s of
        Just ks | k `S.member` ks -> return r
        _ -> return (Left () <$ r)
      _ -> return r
  ,
  cachePopulate = \t k v s -> first (trackKey t k) <$> adapt (\_ -> cachePopulate ca t k v) s
  }


initPureCacheWB :: Persister w -> w -> Loggers -> IO (WB (CacheAdapter Pure.PureDb) w)
initPureCacheWB wp w loggers = do
  wv <- newMVar w
  c <- newChan
  im <- newEmptyMVar
  return WB {
    _cachePersister = persister,
    _cacheState = CacheAdapter {
        _caPersister = Pure.persister,
        _caState = Pure.initPureDb,
        _committedKeys = def,
        _tempKeys = def
        },
    _cacheAccess = initCacheAccess CacheAccess {
        cacheRead = readPureCache,
        cachePopulate = populatePureCache
        },
    _txState = def,
    _wbPersister = wp,
    _wbState = wv,
    _chan = c,
    _immediate = im,
    _logger = newLogger loggers "Persist-WB"
    }

readPureCache :: (PactDbKey k, PactDbValue v) => Table k -> k -> Persist Pure.PureDb (Either () (Maybe v))
readPureCache t k s = case firstOf (Pure.temp . Pure.tblType t . Pure.tbls . ix t) s of
  Nothing -> return (s,Left ()) -- table not found, treat as cache miss
  Just _ -> fmap Right <$> readValue Pure.persister t k s

populatePureCache :: (PactDbKey k, PactDbValue v) => Table k -> k -> Maybe v -> Persist Pure.PureDb ()
populatePureCache t k v = return . (,()) . doInsert Pure.temp . doInsert Pure.committed
  where
    doInsert dbLens = over (dbLens . Pure.tblType t . Pure.tbls) $ \ts -> case (M.lookup t ts,v) of
        (Nothing,Nothing) -> M.insert t (Pure.Tbl M.empty) ts -- new table only
        (Nothing,Just pv) -> M.insert t (Pure.Tbl $ M.singleton k (Pure.PValue pv)) ts -- new table w value
        (Just {},Nothing) -> ts -- known table but key is empty, noop
        (Just (Pure.Tbl pt),Just pv) -> M.insert t (Pure.Tbl $ M.insert k (Pure.PValue pv) pt) ts -- known table w update


regressPureSQLite :: IO ()
regressPureSQLite = do
  (dbe, _ctx) <- initTestPureSQLite "deleteme.sqlite" alwaysLog
  void $ runRegression dbe


-- | Updated version of initTestPureSQLite that additionally returns a CacheContext object
--   that can be used to tell the underlying database thread to exit and also to wait for that
--   thread's completion
initTestPureSQLite
  :: FilePath
     -> Loggers
     -> IO ( DbEnv (WB (CacheAdapter Pure.PureDb) SQLite.SQLite)
           , CacheContext (CacheAdapter Pure.PureDb) SQLite.SQLite)
initTestPureSQLite f logger = do
  doesFileExist f >>= \b -> when b (removeFile f)
  sl <- SQLite.initSQLite (SQLite.SQLiteConfig f []) logger
  wb <- initPureCacheWB SQLite.persister sl logger
  asy <- async (runWBService wb)
  link asy
  return (initDbEnv neverLog WB.persister wb, CacheContext wb asy)

#ifdef DB_ADAPTERS
initTestPureMySQL
     :: Loggers
     -> IO ( DbEnv (WB (CacheAdapter Pure.PureDb) MySQL.MySQL)
           , CacheContext (CacheAdapter Pure.PureDb) MySQL.MySQL)
initTestPureMySQL logger = do
  sl <- MySQL.initMySQL MySQL.testConnectInfo logger

  MySQL.dropRegressTables sl
  wb <- initPureCacheWB MySQL.persister sl logger
  asy <- async (runWBService wb)
  link asy
  return (initDbEnv neverLog WB.persister wb, CacheContext wb asy)
#endif

runDemoWB :: IO ()
runDemoWB = do
  (p, _ctx) <- initTestPureSQLite "deleteme.sqlite" neverLog
  pde <- PactDbEnv pactdb <$> newMVar p
  putStrLn "Creating Pact Schema"
  createSchema (pdPactDbVar pde)
  pcode <- T.pack <$> readFile "test-files/demo.pact"
  let pdata = object [ "demo-admin-keyset" .= object
                         [ "keys" .= [String "demoadmin"]
                         , "pred" .= String ">" ] ]
  rv <- newMVar initRefStore
  let gasLimit = (0 :: Integer) -- TODO implement
  let gasRate = (0 :: Integer) -- TODO implement
  let gasEnv = (GasEnv (fromIntegral gasLimit) 0.0 (constGasModel (fromIntegral gasRate)))
  let doExec pc pd = do
        pc' <- either (throwIO . userError) (return . ParsedCode pc) $
                 AP.parseOnly (unPactParser exprs) pc
        rs <- takeMVar rv
        let evalEnv = setupEvalEnv
                        pde
                        def
                        Transactional
                        (MsgData pd def (pactHash "") def)
                        rs
                        gasEnv
                        permissiveNamespacePolicy
                        noSPVSupport
                        def
                        def
        r <- evalExec defaultInterpreter evalEnv pc'
        putMVar rv (_eeRefStore evalEnv)
        return (_erOutput r)

  print =<< doExec pcode pdata
  print =<< doExec "(demo.read-all)" Null
