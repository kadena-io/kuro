{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE KindSignatures #-}

module Kadena.Util.Combinator
  ( (^$)
  , (^=<<.)
  , foreverRetry
  ) where

--import System.IO (hFlush, stderr, stdout)
import Control.Concurrent (forkFinally, putMVar, takeMVar, newEmptyMVar, forkIO)
import Control.Lens
import Control.Monad.RWS.Strict
--import Data.Thyme.Calendar (showGregorian)
--import Data.Thyme.LocalTime

-- like $, but the function is a lens from the reader environment with a
-- pure function as its target
infixr 0 ^$
(^$) :: forall (m :: * -> *) b r a. (MonadReader r m, Functor m) =>
  Getting (a -> b) r (a -> b) -> a -> m b
lf ^$ a = fmap ($ a) (view lf)

infixr 0 ^=<<.
(^=<<.) :: forall a (m :: * -> *) b r s.
  (MonadReader r m, MonadState s m) =>
  Getting (a -> m b) r (a -> m b) -> Getting a s a -> m b
lf ^=<<. la = view lf >>= (use la >>=)

foreverRetry :: (String -> IO ()) -> String -> IO () -> IO ()
foreverRetry debug threadName action = void $ forkIO $ forever $ do
  threadDied <- newEmptyMVar
  void $ forkFinally (debug (threadName ++ " launching") >> action >> putMVar threadDied ())
    $ \res -> do
      case res of
        Right () -> debug $ threadName ++ " died returning () with no details"
        Left err -> debug $ threadName ++ " exception " ++ show err
      putMVar threadDied ()
  takeMVar threadDied
  debug $ threadName ++ "got MVar... restarting"
