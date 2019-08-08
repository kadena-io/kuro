{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module WireFormatSpec (spec) where

import Test.Hspec

import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Aeson
import Data.Text (Text)
import Data.Maybe

import Kadena.Command
import Kadena.Log
import Kadena.Types
import Kadena.Types.KeySet
import qualified Pact.Types.Command as Pact
import Pact.Types.Crypto
import Pact.Types.RPC

spec :: Spec
spec = do
  describe "WireFormat RoundTrips" testWireRoundtrip
  describe "Hashing stability" testHashingStability

testHashingStability :: Spec
testHashingStability = do
  let testString1 = "foo"
      testString2 = "foo"
      testString3 = "foo"
      testString4 = "foo"
  it "ByteString Stability (unary)" $
    testString1 `shouldBe` testString2
  it "OverloadedStrings ByteString Stability (unary)" $
    testString3 `shouldBe` testString4
  it "ByteString Stability (repeated)" $
    replicate 10 testString1 `shouldBe` replicate 10 testString2
  it "OverloadedStrings ByteString Stability (repeated)" $
    replicate 10 testString3 `shouldBe` replicate 10 testString4
  it "Stability (unary)" $
    hash testString1 `shouldBe` hash testString1
  it "Stability (repeated)" $
    (hash <$> replicate 10 testString1) `shouldBe` (hash <$> replicate 10 testString1)
  it "Equiv 1" $
    hash testString1 `shouldBe` hash testString2
  it "Equiv 3" $
    hash testString3 `shouldBe` hash testString3
  it "Equiv 4" $
    hash testString3 `shouldBe` hash testString4

testWireRoundtrip :: Spec
testWireRoundtrip = do
  it "Command" $
    fromWire Nothing keySet cmdSignedRPC1
      `shouldBe`
        (Right $ cmdRPC1 {
            _newProvenance = ReceivedMsg
              { _pDig = _sigDigest cmdSignedRPC1
              , _pOrig = _sigBody cmdSignedRPC1
              , _pTimeStamp = Nothing}})
  it "Seq LogEntry" $
    leSeqDecoded `shouldBe` leSeq
  it "RequestVoteResponse" $
    fromWire Nothing keySet rvrSignedRPC1
      `shouldBe`
        (Right $ rvrRPC1 {
            _rvrProvenance = ReceivedMsg
              { _pDig = _sigDigest rvrSignedRPC1
              , _pOrig = _sigBody rvrSignedRPC1
              , _pTimeStamp = Nothing}})
  it "Set RequestVoteResponse" $
    decodeRVRWire Nothing keySet rvrSignedRPCList `shouldBe` Right rvrRPCSet'
  it "AppendEntries" $
    fromWire Nothing keySet aeSignedRPC
      `shouldBe`
        (Right $ aeRPC {
            _aeProvenance = ReceivedMsg
              { _pDig = _sigDigest aeSignedRPC
              , _pOrig = _sigBody aeSignedRPC
              , _pTimeStamp = Nothing}})

  it "AppendEntriesResponse" $
    fromWire Nothing keySet aerSignedRPC
      `shouldBe`
        (Right $ aerRPC {
            _aerProvenance = ReceivedMsg
              { _pDig = _sigDigest aerSignedRPC
              , _pOrig = _sigBody aerSignedRPC
              , _pTimeStamp = Nothing}})

  it "RequestVote" $
    fromWire Nothing keySet rvSignedRPC
      `shouldBe`
        (Right $ rvRPC {
            _rvProvenance = ReceivedMsg
              { _pDig = _sigDigest rvSignedRPC
              , _pOrig = _sigBody rvSignedRPC
              , _pTimeStamp = Nothing}})

-- ##########################################################
-- ####### All the stuff we need to actually run this #######
-- ##########################################################

-- #######################################################################
-- NodeId's + Keys for Leader (10000) and Follower (10001)
-- #######################################################################
nodeIdLeader, nodeIdFollower :: NodeId
nodeIdLeader = NodeId "localhost" 10000 "tcp://127.0.0.1:10000" $ Alias "leader"
nodeIdFollower = NodeId "localhost" 10001 "tcp://127.0.0.1:10001" $ Alias "follower"

privKeyLeader, privKeyFollower, privKeyClient :: PrivateKey
privKeyLeader = fromMaybe (error "bad key") $
  importPrivate "\204m\223Uo|\211.\144\131\&5Xmlyd$\165T\148\&11P\142m\249\253$\216\232\220c"
privKeyFollower = fromMaybe (error "bad key") $
  importPrivate "$%\181\214\b\138\246(5\181%\199\186\185\t!\NUL\253'\t\ENQ\212^\236O\SOP\217\ACK\EOT\170<"
privKeyClient = fromMaybe (error "bad key") $
  importPrivate "8H\r\198a;\US\249\233b\DLE\211nWy\176\193\STX\236\SUB\151\206\152\tm\205\205\234(\CAN\254\181"

pubKeyLeader, pubKeyFollower, pubKeyClient :: PublicKey
pubKeyLeader = fromMaybe (error "bad key") $
  importPublic "f\t\167y\197\140\&2c.L\209;E\181\146\157\226\137\155$\GS(\189\215\SUB\199\r\158\224\FS\190|"
pubKeyFollower = fromMaybe (error "bad key") $
  importPublic "\187\182\129\&4\139\197s\175Sc!\237\&8L \164J7u\184;\CANiC\DLE\243\ESC\206\249\SYN\189\ACK"
pubKeyClient = fromMaybe (error "bad key") $
  importPublic "@*\228W(^\231\193\134\239\254s\ETBN\208\RS\137\201\208,bEk\213\221\185#\152\&7\237\234\DC1"

keySet :: KeySet
keySet = KeySet
  { _ksCluster = Map.fromList [(_alias nodeIdLeader, pubKeyLeader),
                               (_alias nodeIdFollower, pubKeyFollower)] }

-- #####################################
-- Commands, with and without provenance
-- #####################################
cmdRPC1, cmdRPC2 :: NewCmdRPC
cmdRPC1 = NewCmdRPC
          { _newCmd =
            [encodeCommand $
              SmartContractCommand
              { _sccCmd = Pact.mkCommand [(ED25519,privKeyClient,pubKeyClient)] Nothing "nonce1"
                          (Exec (ExecMsg ("(+ 1 2)" :: Text) Null))
              , _sccPreProc = Unprocessed
              }]
          , _newProvenance = NewMsg }
cmdRPC2 = NewCmdRPC
          { _newCmd =
            [encodeCommand $
              SmartContractCommand
              { _sccCmd = Pact.mkCommand [(ED25519,privKeyClient,pubKeyClient)] Nothing "nonce2"
                          (Exec (ExecMsg ("(+ 3 4)" :: Text) Null))
              , _sccPreProc = Unprocessed
              }]
          , _newProvenance = NewMsg }

cmdSignedRPC1, cmdSignedRPC2 :: SignedRPC
cmdSignedRPC1 = toWire nodeIdLeader pubKeyLeader privKeyLeader cmdRPC1
cmdSignedRPC2 = toWire nodeIdFollower pubKeyFollower privKeyFollower cmdRPC2

-- these are signed (received) provenance versions
cmdRPC1', cmdRPC2' :: Command
cmdRPC1' = either error (decodeCommand . head . _newCmd) $ fromWire Nothing keySet cmdSignedRPC1
cmdRPC2' = either error (decodeCommand . head . _newCmd) $ fromWire Nothing keySet cmdSignedRPC2

-- ########################################################
-- LogEntry(s) and Seq LogEntry with correct hashes.
-- LogEntry is not an RPC but is(are) nested in other RPCs.
-- Given this, they are handled differently (no provenance)
-- ########################################################
logEntry1, logEntry2 :: LogEntry
logEntry1 = hashLogEntry Nothing $ LogEntry
  { _leTerm    = Term 0
  , _leLogIndex = 0
  , _leCommand = cmdRPC1'
  , _leHash    = hash "logEntry1"
  , _leCmdLatMetrics = Nothing
  }
logEntry2 = hashLogEntry (Just $ _leHash logEntry1) $ LogEntry
  { _leTerm    = Term 0
  , _leLogIndex = 1
  , _leCommand = cmdRPC2'
  , _leHash    = hash "logEntry2"
  , _leCmdLatMetrics = Nothing
  }

leSeq, leSeqDecoded :: LogEntries
leSeq = (\(Right v) -> v) $ checkLogEntries $ Map.fromList [(0,logEntry1),(1,logEntry2)]
leSeqDecoded = (\(Right v) -> v) $ decodeLEWire Nothing leWire

leWire :: [LEWire]
leWire = encodeLEWire leSeq

-- ################################################
-- RequestVoteResponse, with and without provenance
-- ################################################

rvrRPC1, rvrRPC2 :: RequestVoteResponse
rvrRPC1 = RequestVoteResponse
  { _rvrTerm        = Term 0
  , _rvrHeardFromLeader = Nothing
  , _rvrNodeId      = nodeIdLeader
  , _voteGranted    = True
  , _rvrCandidateId = nodeIdLeader
  , _rvrProvenance  = NewMsg
  }
rvrRPC2 = RequestVoteResponse
  { _rvrTerm        = Term 0
  , _rvrHeardFromLeader = Nothing
  , _rvrNodeId      = nodeIdFollower
  , _voteGranted    = True
  , _rvrCandidateId = nodeIdLeader
  , _rvrProvenance  = NewMsg
  }

rvrSignedRPC1, rvrSignedRPC2 :: SignedRPC
rvrSignedRPC1 = toWire nodeIdLeader pubKeyLeader privKeyLeader rvrRPC1
rvrSignedRPC2 = toWire nodeIdFollower pubKeyFollower privKeyFollower rvrRPC2

rvrRPC1', rvrRPC2' :: RequestVoteResponse
rvrRPC1' = (\(Right v) -> v) $ fromWire Nothing keySet rvrSignedRPC1
rvrRPC2' = (\(Right v) -> v) $ fromWire Nothing keySet rvrSignedRPC2

rvrRPCSet' :: Set RequestVoteResponse
rvrRPCSet' = Set.fromList [rvrRPC1', rvrRPC2']

rvrSignedRPCList :: [SignedRPC]
rvrSignedRPCList = [rvrSignedRPC1, rvrSignedRPC2]

-- #############################################
-- AppendEntries, with and without provenance
-- #############################################
aeRPC :: AppendEntries
aeRPC = AppendEntries
  { _aeTerm        = Term 0
  , _leaderId      = nodeIdLeader
  , _prevLogIndex  = LogIndex (-1)
  , _prevLogTerm   = Term 0
  , _aeEntries     = leSeq
  , _aeQuorumVotes = rvrRPCSet'
  , _aeProvenance  = NewMsg
  }


aeSignedRPC :: SignedRPC
aeSignedRPC = toWire nodeIdLeader pubKeyLeader privKeyLeader aeRPC


-- #####################
-- AppendEntriesResponse
-- #####################
aerRPC :: AppendEntriesResponse
aerRPC = AppendEntriesResponse
  { _aerTerm       = Term 0
  , _aerNodeId     = nodeIdFollower
  , _aerSuccess    = True
  , _aerConvinced  = True
  , _aerIndex      = LogIndex 1
  , _aerHash       = hash "hello"
  , _aerProvenance = NewMsg
  }

aerSignedRPC :: SignedRPC
aerSignedRPC = toWire nodeIdFollower pubKeyFollower privKeyFollower aerRPC


-- ###########
-- RequestVote
-- ###########
rvRPC :: RequestVote
rvRPC = RequestVote
  { _rvTerm        = Term 0
  , _rvCandidateId = nodeIdLeader
  , _rvLastLogIndex  = LogIndex (-1)
  , _rvLastLogTerm   = Term (-1)
  , _rvProvenance  = NewMsg
  }

rvSignedRPC :: SignedRPC
rvSignedRPC = toWire nodeIdLeader pubKeyLeader privKeyLeader rvRPC
