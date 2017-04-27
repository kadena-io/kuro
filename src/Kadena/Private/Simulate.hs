{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Kadena.Private.Simulate

  where


import Control.Lens
import Crypto.Noise.DH (dhGenKey)
import qualified Data.Set as S
import Control.Monad.State.Strict
import Control.Monad.Catch
import Data.ByteString (ByteString)

import Pact.Types.Orphans ()

import Kadena.Types.Base (Alias)

import Kadena.Private.Types
import Kadena.Private.Private


type SimNode = (PrivateEnv,PrivateState)
data ABC = ABC {
    _a1 :: SimNode
  , _a2 :: SimNode
  , _b1 :: SimNode
  , _b2 :: SimNode
  , _c1 :: SimNode
  , _c2 :: SimNode }
makeLenses ''ABC


simulate :: IO ()
simulate = do

  aStatic <- dhGenKey
  aEph <- dhGenKey
  bStatic <- dhGenKey
  bEph <- dhGenKey
  cStatic <- dhGenKey
  cEph <- dhGenKey

  let aRemote = EntityRemote "A" (kpPublic $ aStatic)
      bRemote = EntityRemote "B" (kpPublic $ bStatic)
      cRemote = EntityRemote "C" (kpPublic $ cStatic)

      aEntity = EntityLocal "A" aStatic aEph
      bEntity = EntityLocal "B" bStatic bEph
      cEntity = EntityLocal "C" cStatic cEph

  abc <- ABC
    <$> initNode aEntity [bRemote,cRemote] "A1"
    <*> initNode aEntity [bRemote,cRemote] "A2"
    <*> initNode bEntity [aRemote,cRemote] "B1"
    <*> initNode bEntity [aRemote,cRemote] "B2"
    <*> initNode cEntity [aRemote,bRemote] "C1"
    <*> initNode cEntity [aRemote,bRemote] "C2"

  void $ (`runStateT` abc) $ do

    runReceiveAll =<< runSend a1 ["B"] "1 Hello B!"

    runReceiveAll =<< runSend b1 ["A","C"] "2 Hello A,C!"

    -- TODO needs to happen before C can send, need initialization protocol
    runReceiveAll =<< runSend a2 ["C"] "3 C from A2"

    runReceiveAll =<< runSend c1 ["A","B"] "4 Hello A,B!"

    runReceiveAll =<< runSend b2 ["A"] "5 A from B2"

    runReceiveAll =<< runSend a1 ["B","C"] "6 B,C from A1"

    -- interleaving
    {- BROKEN, committing working version
    mc1 <- runSend c2 ["A"] "7 A from C2"
    mc2 <- runSend c2 ["A","B"] "8 A,B from C2"
    runReceiveAll mc1
    runReceiveAll mc2
    -}


runSend :: Lens' ABC SimNode -> [EntityName] -> ByteString ->
           StateT ABC IO (PrivateMessage,PrivateEnvelope)
runSend node to' msg = do
  entName <- use (node . _1 . entityLocal . elName)
  alias <- use (node . _1 . nodeAlias)
  pm1 <- return $ PrivateMessage entName alias (S.fromList to') msg
  putStrLn' $ "SEND: " ++ show pm1
  pe1 <- run node $ sendPrivate pm1
  return (pm1,pe1)

runReceiveAll :: (PrivateMessage,PrivateEnvelope) -> StateT ABC IO ()
runReceiveAll m = do
  putStrLn' $ "RECEIVE ALL: " ++ show (_pmMessage (fst m))
  forM_ [a1,a2,b1,b2,c1,c2] $ \n -> runReceive m n


runReceive :: (PrivateMessage, PrivateEnvelope) -> ALens' ABC SimNode -> StateT ABC IO ()
runReceive (pm@PrivateMessage{..}, pe) anode = do
  entName <- use (cloneLens anode . _1 . entityLocal . elName)
  alias <- use (cloneLens anode . _1 . nodeAlias)
  pm' <- catch (run anode $ handlePrivate pe)
    (\(e :: SomeException) -> throwM (userError ("runReceive:" ++ show alias ++ ":" ++ show e)))
  if _pmFrom == entName || entName `S.member` _pmTo then
    assertEq (show entName ++ ": receipt") (Just pm) pm'
    else
    assertEq (show entName ++ ": no receipt") Nothing pm'



run :: ALens' ABC SimNode -> Private a -> StateT ABC IO a
run node a = do
  (e,s) <- use (cloneLens node)
  (r,s') <- liftIO $ runPrivate e s a
  (cloneLens node . _2) .= s'
  return r

assertEq :: (Eq a, Show a, MonadThrow m) => String -> a -> a -> m ()
assertEq msg e a
  | e == a = return ()
  | otherwise =
      die $ "assertEq: " ++ msg ++ ", expected=" ++ show e ++ ",actual=" ++ show a


initNode :: MonadThrow m => EntityLocal-> [EntityRemote] -> Alias -> m SimNode
initNode ent rems alias = do
  ss <- initSessions ent rems
  return (PrivateEnv ent rems alias,PrivateState ss)

print' :: (MonadIO m,Show a) => a -> m ()
print' = liftIO . print

putStrLn' :: MonadIO m => String -> m ()
putStrLn' = liftIO . putStrLn
