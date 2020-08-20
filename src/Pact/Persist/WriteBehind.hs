{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}

-- keep all keys??
module Pact.Persist.WriteBehind where

import Control.Lens
import Control.Concurrent.MVar
import Control.Monad
import Control.Concurrent.Chan
import Control.Monad.Catch
import qualified Data.Set as S
import qualified Data.Map.Strict as M
import Data.Default

import Pact.Persist
import Pact.Types.Logger
import Pact.Types.Persistence

data CacheAccess c = CacheAccess {
  -- | Return result where Right is reliable result, Left means cache miss, which could indicate
  -- a table that the cache is not aware of.
  cacheRead :: forall k v . (PactDbKey k, PactDbValue v) => Table k -> k -> Persist c (Either () (Maybe v)),
  -- | Used to populate cache after miss, possibly creating table in cache.
  cachePopulate :: forall k v . (PactDbKey k, PactDbValue v) => Table k -> k -> Maybe v -> Persist c ()
  }

data WbTxState w = WbTxState {
  _wtCmds :: [Cmd w],
  _wtNewDataTables :: S.Set DataTable,
  _wtNewTxTables :: S.Set TxTable,
  _wtActive :: ExecutionMode
  } deriving (Show)
instance Default (WbTxState w) where def = WbTxState def def def Local


data WB c w = WB {
  _cachePersister :: Persister c,
  _cacheState :: c,
  _cacheAccess :: CacheAccess c,
  _txState :: WbTxState w,
  _wbPersister :: Persister w,
  _wbState :: MVar w,
  _chan :: Chan (Msg w),
  _immediate :: MVar (Cmd w),
  _logger :: Logger
  }

data Cmd w = Cmd String (Persister w -> Persist w ())
instance Show (Cmd w) where show (Cmd s _) = show s

data Msg w = Tx [Cmd w] | Solo (Cmd w) | Stop String

makeLenses ''WB
makeLenses ''WbTxState

wtNewTables :: Table k -> Lens' (WbTxState w) (S.Set (Table k))
wtNewTables DataTable {} = wtNewDataTables
wtNewTables TxTable {} = wtNewTxTables

onCache :: (Persister c -> Persist c a) -> Persist (WB c w) a
onCache f s@WB {..} = do
  (cs',r) <- f _cachePersister _cacheState
  return (s { _cacheState = cs' },r)
{-# INLINE onCache #-}

persister :: Persister (WB c w)
persister = Persister {

  createTable = createTable'
  ,
  beginTx = beginTx'
  ,
  commitTx = commitTx'
  ,
  rollbackTx = rollbackTx'
  ,
  queryKeys = queryKeys'
  ,
  query = query'
  ,
  readValue = readValue'
  ,
  writeValue = writeValue'
  ,
  refreshConn = refreshConn'

  }

createTable' :: PactDbKey k => Table k -> Persist (WB c w) ()
createTable' t s =
  enqueueTxCmd (Cmd ("createTable: " ++ show t) (\p -> createTable p t)) .
  over (_1 . txState . wtNewTables t) (S.insert t)
  <$> onCache (\p -> createTable p t) s

isNewTableForTx :: Table k -> WB c w -> Bool
isNewTableForTx t = S.member t . view (txState . wtNewTables t)


resetTxState :: ExecutionMode -> WB c w -> WB c w
resetTxState inTx = set txState (def { _wtActive = inTx })

enqueueTxCmd :: Cmd w -> (WB c w,a) -> (WB c w,a)
enqueueTxCmd c = over (_1 . txState . wtCmds) (c:)

beginTx' :: ExecutionMode -> Persist (WB c w) ()
beginTx' m s = over _1 (resetTxState m) <$> onCache (\p -> beginTx p m) s

commitTx' :: Persist (WB c w) ()
commitTx' s = do
  writeChan (_chan s) (Tx $ _wtCmds $ _txState s)
  over _1 (resetTxState Local) <$> onCache commitTx s

rollbackTx' :: Persist (WB c w) ()
rollbackTx' s = over _1 (resetTxState Local) <$> onCache rollbackTx s

-- | Queries union cache and backend results.
queryKeys' :: PactDbKey k => Table k -> Maybe (KeyQuery k) -> Persist (WB c w) [k]
queryKeys' t kq s = do
  mv <- newEmptyMVar
  execImmediateOrEnqueue s $ Cmd ("queryKeys: " ++ show t ++ "," ++ show kq) $ \p w -> do
    (w',r) <- queryKeys p t kq w
    putMVar mv r
    return (w',())
  r <- takeMVar mv
  (s',cr) <- onCache (\p -> queryKeys p t kq) s
  return (s',S.toList (S.fromList cr `S.union` S.fromList r))

-- | Queries union cache and backend results.
query' :: (PactDbKey k, PactDbValue v) => Table k -> Maybe (KeyQuery k) -> Persist (WB c w) [(k,v)]
query' t kq s = do
  mv <- newEmptyMVar
  execImmediateOrEnqueue s $ Cmd ("query: " ++ show t ++ "," ++ show kq) $ \p w -> do
    (w',r) <- query p t kq w
    putMVar mv r
    return (w',())
  r <- takeMVar mv
  (s',cr) <- onCache (\p -> query p t kq) s
  return (s',M.toList (M.fromList cr `M.union` M.fromList r))

-- | READ: perform cache read to see if value is tracked in cache, if
-- so return that value. Otherwise hit backend and block for result.
readValue' :: (PactDbKey k, PactDbValue v) => Table k -> k -> Persist (WB c w) (Maybe v)
readValue' t k s = do
  (s',cr) <- onCache (\_ -> cacheRead (_cacheAccess s) t k) s
  case (cr,isNewTableForTx t s') of
    (Right r,_) -> return (s',r)
    (Left (),True) -> return (s',Nothing)
    (Left (),_) -> do
      mv <- newEmptyMVar
      enqueueCmd s $ Cmd ("readValue: " ++ show t ++ "," ++ show k) $ \p w -> do
        (w',r) <- readValue p t k w
        putMVar mv r
        return (w',())
      v <- takeMVar mv
      (s'',_) <- onCache (\_ -> cachePopulate (_cacheAccess s) t k v) s'
      return (s'',v)

-- | WRITE: if WriteType is 'Write' simply write to cache and add WB command.
-- For insert or update, a cache refresh may be necessary, so here we do
-- a throwaway read, with the assumption that an in-cache read is not significantly
-- more expensive than some kind of dedicated key-only "are we tracking this key" check.
writeValue' :: (PactDbKey k, PactDbValue v) => Table k -> WriteType -> k -> v -> Persist (WB c w) ()
writeValue' t wt k v s = do
  (s',_) <- case (wt,isNewTableForTx t s) of
    (Write,_) -> return (s,Just v)
    (_,True) -> return (s,Just v)
    _ -> readValue' t k s -- throwaway read to refresh cache for insert or update
  enqueueTxCmd (Cmd ("writeValue: " ++ show t ++ "," ++ show k) (\p -> writeValue p t wt k v)) <$>
    onCache (\p -> writeValue p t wt k v) s'


-- | Blocking call to refresh backend connection.
refreshConn' :: Persist (WB c w) ()
refreshConn' s = do
  (s',_) <- onCache refreshConn s
  mv <- newEmptyMVar
  execImmediate s' $ Cmd "refreshConn" $ \p w -> do
    r <- refreshConn p w
    putMVar mv ()
    return r
  void $ takeMVar mv
  return (s',())

-- | In transactional settings respects queueing;
-- in nontransactional settings, fires immediately.
execImmediateOrEnqueue :: WB c w -> Cmd w -> IO ()
execImmediateOrEnqueue w@WB{..} c
  | (_wtActive _txState == Transactional) = enqueueCmd w c
  | otherwise = execImmediate w c

-- | Block to populate immediate mvar; enqueue noop
-- to wake from `readChan` if necessary.
execImmediate :: WB c w -> Cmd w -> IO ()
execImmediate wb@WB{..} c = do
  putMVar _immediate c
  enqueueCmd wb $ Cmd "Noop" $ \_ w -> return (w,())

enqueueCmd :: WB c w -> Cmd w -> IO ()
enqueueCmd WB{..} c = writeChan _chan (Solo c)

-- | Enqueue the command to stop the underlying database access thread
enqueueStop :: WB c w -> String -> IO ()
enqueueStop WB{..} str = writeChan _chan (Stop str)

wblog :: WB c w -> String -> String -> IO ()
wblog e = logLog (_logger e)

-- | A single queue-service pass.
service :: WB c w -> IO (Maybe String)
service s@WB{..} = do
  immed <- tryTakeMVar _immediate
  msg <- case immed of
    Just c -> return $ Solo c
    Nothing -> readChan _chan
  let p = _wbPersister
  handle (\(e :: SomeException) -> do
             wblog s "ERROR" $ "write failed for transaction: " ++ show e
             return Nothing) $
         modifyMVar _wbState $ \w ->
           case msg of
             Solo (Cmd _s f) -> (Nothing <$) <$> f p w
             Tx cs -> do
               (w',_) <- beginTx p Transactional w
               w'' <- foldM (\x (Cmd _s f) -> fst <$> f p x) w' (reverse cs)
               (Nothing <$) <$> commitTx p w''
             Stop m -> return (w,Just m)

runWBService :: WB c w -> IO ()
runWBService s = go where
  go = service s >>= \r -> case r of
    Just m -> wblog s "INFO" $ "Shutting down: " ++ m
    Nothing -> go
