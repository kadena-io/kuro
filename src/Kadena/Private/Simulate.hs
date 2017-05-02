{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Kadena.Private.Simulate

  where


import Control.Lens hiding (levels)
import Crypto.Noise.DH (dhGenKey)
import qualified Data.Set as S
import Control.Monad.State.Strict
import Control.Monad.Catch
import Data.ByteString (ByteString)
import qualified Data.HashMap.Strict as HM
import qualified Data.ByteString.Char8 as B8
import Data.Tree
import Data.List

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
  , _c2 :: SimNode
  , _sent :: HM.HashMap Int (PrivateMessage,PrivateEnvelope)
  }
makeLenses ''ABC

initNodes :: IO ABC
initNodes = do

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

  ABC <$> initNode aEntity [bRemote,cRemote] "A1"
        <*> initNode aEntity [bRemote,cRemote] "A2"
        <*> initNode bEntity [aRemote,cRemote] "B1"
        <*> initNode bEntity [aRemote,cRemote] "B2"
        <*> initNode cEntity [aRemote,bRemote] "C1"
        <*> initNode cEntity [aRemote,bRemote] "C2"
        <*> pure HM.empty



simulate1 :: IO ()
simulate1 = do

  abc <- initNodes


  void $ (`runStateT` abc) $ do

    runReceiveAll =<< runSend a1 ["B"] "1 Hello B!"

    runReceiveAll =<< runSend b1 ["A","C"] "2 Hello A,C!"

    -- TODO needs to happen before C can send, need initialization protocol
    runReceiveAll =<< runSend a2 ["C"] "3 C from A2"

    runReceiveAll =<< runSend c1 ["A","B"] "4 Hello A,B!"

    runReceiveAll =<< runSend b2 ["A"] "5 A from B2"

    runReceiveAll =<< runSend a1 ["B","C"] "6 B,C from A1"

    -- interleaving
    mc1 <- runSend c2 ["A"] "7 A from C2"
    mc2 <- runSend c2 ["A","B"] "8 A,B from C2"
    runReceiveAll mc1
    runReceiveAll mc2

simulate2 :: Int -> IO ()
simulate2 numMsgs = do
  let msgs :: [Message EntityName]
      msgs = [Message 0 "A" ["B","C"]
              ,Message 1 "B" ["C","A"]
              ,Message 2 "C" ["A","B"]
              ]
      paths = getPaths $ mkTree (take numMsgs msgs) ["A","B","C"]
      getNode :: EntityName -> (ALens' ABC SimNode,ALens' ABC SimNode)
      getNode "A" = (a1,a2)
      getNode "B" = (b1,b2)
      getNode "C" = (c1,c2)
      getNode n = error $ "bad node: " ++ show n

  forM_ paths $ \path -> initNodes >>= \abc -> (`runStateT` abc) $ do
    -- putStrLn' "====================================="
    -- print' path

    let mkMessage :: Message EntityName -> StateT ABC IO (ALens' ABC SimNode,Int,PrivateMessage)
        mkMessage m@(Message i f tos) = do
          let (s1,_) = getNode f
          sender <- use (cloneLens s1)
          return (s1,i,PrivateMessage f
                   (_nodeAlias (fst sender)) (S.fromList tos) (B8.pack (show m)))

    forM_ path $ \ev -> do
      --print' ev
      case ev of
        Send m _ -> do
          (n,i,pm) <- mkMessage m
          --print' (i,pm)
          pe <- run n $ sendPrivate pm
          --print' (i,pm,pe)
          sent %= HM.insert i (pm,pe)
        Read (Inbox n ms) _ -> do
          let (Message i _ _) = head ms
              (n1,n2) = getNode n
          mm <- (HM.! i) <$> use sent
          --print' (i,mm)
          runReceive mm n1
          runReceive mm n2


data Message n = Message Int n [n] deriving (Show,Eq,Ord)
data Inbox m n = Inbox n [m] deriving (Eq,Show)
data Event m n =
  Send m [Event m n] |
  Read (Inbox m n) [Event m n] deriving (Eq)
instance (Show n,Show m) => Show (Event m n) where
  show (Send m _) = "Send: " ++ show m
  show (Read i _) = "Read: " ++ show i
data Gen m n = Gen [m] [Inbox m n] deriving (Eq,Show)

-- | generate messages over all possible from->tos for node count
mkMsgs :: Int -> [Message Int]
mkMsgs nodeCount = number $ concatMap (\f -> Message 0 f (delete f nodes):
                               map (Message 0 f . pure) (delete f nodes)) nodes
  where nodes = [0 .. nodeCount - 1]
        number = zipWith (\i (Message _ f t) -> Message i f t)  [0..]

mkTree :: (Eq m,Eq n) => [m] -> [n] -> Tree (Event m n)
mkTree msgs nodes = unfoldTree go (Send (head msgs) [], Gen msgs inboxes)
  where
    inboxes = map (`Inbox` []) nodes
    go (ev,Gen gms ibxs) = (ev,mkSend ++ mkReads) where
      (ibxs',gms',path) = case ev of
        Send m p -> (map (queue m) ibxs,delete m gms,p)
        Read _ p -> (ibxs,gms,p)
      mkSend = case gms' of (m:_) -> [(Send m (ev:path), Gen gms' ibxs')]
                            [] -> []
      mkReads = (`concatMap` ibxs') $ \ibx@(Inbox n ims) ->
        case ims of
          [] -> []
          (_:ms) -> [(Read ibx (ev:path), Gen gms' (Inbox n ms:delete ibx ibxs'))]
      queue m (Inbox n ms) = Inbox n (m:ms)

getPaths :: Tree (Event n m) -> [[Event n m]]
getPaths t = go t [] where
  path e = reverse $ e:(case e of Send _ p -> p; Read _ p -> p)
  go (Node ev chs) r = case chs of
    [] -> path ev:r
    _ -> concatMap (`go` r) chs




printNode :: Lens' ABC SimNode -> StateT ABC IO ()
printNode node = do
  (PrivateEnv{..},PrivateState Sessions{..}) <- use node
  putStrLn' "========================="
  print' (_entityLocal,_nodeAlias)
  print' _sEntity
  mapM_ print' (HM.elems _sRemotes)
  mapM_ print' (HM.toList _sLabels)
  putStrLn' "========================="

runSend :: Lens' ABC SimNode -> [EntityName] -> ByteString ->
           StateT ABC IO (PrivateMessage,PrivateEnvelope)
runSend node to' msg = do
  entName <- use (node . _1 . entityLocal . elName)
  alias <- use (node . _1 . nodeAlias)
  pm1 <- return $ PrivateMessage entName alias (S.fromList to') msg
  -- putStrLn' $ "SEND: " ++ show pm1
  pe1 <- run node $ sendPrivate pm1
  return (pm1,pe1)

runReceiveAll :: (PrivateMessage,PrivateEnvelope) -> StateT ABC IO ()
runReceiveAll m = do
  -- putStrLn' $ "RECEIVE ALL: " ++ show (_pmMessage (fst m))
  forM_ [a1,a2,b1,b2,c1,c2] $ \n -> runReceive m n


runReceive :: (PrivateMessage, PrivateEnvelope) -> ALens' ABC SimNode -> StateT ABC IO ()
runReceive (pm@PrivateMessage{..}, pe) anode = do
  entName <- use (cloneLens anode . _1 . entityLocal . elName)
  alias <- use (cloneLens anode . _1 . nodeAlias)
  pm' <- catch (run anode $ handlePrivate pe)
    (\(e :: SomeException) -> throwM (userError ("runReceive[" ++ show alias ++ "]: " ++ show e ++ ", env=" ++ show pe)))
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
