{-# LANGUAGE OverloadedStrings #-}

module LogSpec where

import Test.Hspec

import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set


import Juno.Types
import Juno.Types.Service.Log hiding (keySet)

spec :: Spec
spec = describe "WireFormat RoundTrips" testWireRoundtrip

testWireRoundtrip :: Spec
testWireRoundtrip = do
--  it "Command" $
--    fromWire Nothing keySet cmdSignedRPC1
--      `shouldBe`
--        (Right $ cmdRPC1 {
--            _cmdProvenance = ReceivedMsg
--              { _pDig = _sigDigest cmdSignedRPC1
--              , _pOrig = _sigBody cmdSignedRPC1
--              , _pTimeStamp = Nothing}})
  it "lesCnt" $
    (lesCnt $ mkLogEntries 0 9) `shouldBe` 10


-- ##########################################################
-- ####### All the stuff we need to actually run this #######
-- ##########################################################

-- #######################################################################
-- NodeId's + Keys for Client (10002), Leader (10000) and Follower (10001)
-- #######################################################################
nodeIdLeader, nodeIdFollower, nodeIdClient :: NodeId
nodeIdLeader = NodeId "localhost" 10000 "tcp://127.0.0.1:10000" $ Alias "leader"
nodeIdFollower = NodeId "localhost" 10001 "tcp://127.0.0.1:10001" $ Alias "follower"
nodeIdClient = NodeId "localhost" 10002 "tcp://127.0.0.1:10002" $ Alias "client"

privKeyLeader, privKeyFollower, privKeyClient :: PrivateKey
privKeyLeader = maybe (error "bad leader key") id $ importPrivate "\204m\223Uo|\211.\144\131\&5Xmlyd$\165T\148\&11P\142m\249\253$\216\232\220c"
privKeyFollower = maybe (error "bad leader key") id $ importPrivate "$%\181\214\b\138\246(5\181%\199\186\185\t!\NUL\253'\t\ENQ\212^\236O\SOP\217\ACK\EOT\170<"
privKeyClient = maybe (error "bad leader key") id $ importPrivate "8H\r\198a;\US\249\233b\DLE\211nWy\176\193\STX\236\SUB\151\206\152\tm\205\205\234(\CAN\254\181"

pubKeyLeader, pubKeyFollower, pubKeyClient :: PublicKey
pubKeyLeader = maybe (error "bad leader key") id $ importPublic "f\t\167y\197\140\&2c.L\209;E\181\146\157\226\137\155$\GS(\189\215\SUB\199\r\158\224\FS\190|"
pubKeyFollower = maybe (error "bad leader key") id $ importPublic "\187\182\129\&4\139\197s\175Sc!\237\&8L \164J7u\184;\CANiC\DLE\243\ESC\206\249\SYN\189\ACK"
pubKeyClient = maybe (error "bad leader key") id $ importPublic "@*\228W(^\231\193\134\239\254s\ETBN\208\RS\137\201\208,bEk\213\221\185#\152\&7\237\234\DC1"

keySet :: KeySet
keySet = KeySet
  { _ksCluster = Map.fromList [(nodeIdLeader, pubKeyLeader),(nodeIdFollower, pubKeyFollower)]
  , _ksClient = Map.fromList [(nodeIdClient, pubKeyClient)] }

cmdRPC :: Int -> Command
cmdRPC i = Command
  { _cmdEntry = CommandEntry "CreateAccount foo"
  , _cmdClientId = nodeIdClient
  , _cmdRequestId = RequestId $ fromIntegral i
  , _cmdEncryptGroup = Nothing
  , _cmdCryptoVerified = Valid
  , _cmdProvenance = NewMsg }

-- these are signed (received) provenance versions
cmdRPC' :: Int -> Command
cmdRPC' i = (\(Right v) -> v) $ fromWire Nothing keySet $ toWire nodeIdClient pubKeyClient privKeyClient $ cmdRPC i

-- ########################################################
-- LogEntry(s) and Seq LogEntry with correct hashes.
-- LogEntry is not an RPC but is(are) nested in other RPCs.
-- Given this, they are handled differently (no provenance)
-- ########################################################
logEntry :: Int -> LogEntry
logEntry i = LogEntry
  { _leTerm    = Term 0
  , _leLogIndex = LogIndex i
  , _leCommand = cmdRPC' i
  , _leHash    = ""
  }

mkLogEntries :: Int -> Int -> LogEntries
mkLogEntries stIdx endIdx = (\(Right v) -> v) $ checkLogEntries $ Map.fromList $ fmap (\i -> (fromIntegral i, logEntry i)) [stIdx..endIdx]
