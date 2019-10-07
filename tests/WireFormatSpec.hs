{-# LANGUAGE TypeFamilies, GADTs, DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module WireFormatSpec (spec) where

import Test.Hspec

import qualified Crypto.Ed25519.Pure as Ed25519

import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Aeson
import Data.Text (Text)
import Data.Maybe

import System.Exit

import Kadena.Command
import qualified Kadena.Types.Crypto as KC
import Kadena.Log
import Kadena.Types
import qualified Pact.Types.Command as P
import qualified Pact.Types.Crypto as P
import qualified Pact.Types.Hash as P
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
    P.pactHash testString1 `shouldBe` P.pactHash testString1
  it "Stability (repeated)" $
    (P.pactHash <$> replicate 10 testString1) `shouldBe` (P.pactHash <$> replicate 10 testString1)
  it "Equiv 1" $
    P.pactHash testString1 `shouldBe` P.pactHash testString2
  it "Equiv 3" $
    P.pactHash testString3 `shouldBe` P.pactHash testString3
  it "Equiv 4" $
    P.pactHash testString3 `shouldBe` P.pactHash testString4

testWireRoundtrip :: Spec
testWireRoundtrip = do
  it "Command" $ do
    cmd1 <- cmdRPC1
    signed1 <- cmdSignedRPC1
    fromWire Nothing keySet signed1
      `shouldBe`
        (Right $ cmd1 {
            _newProvenance = ReceivedMsg
              { _pDig = _sigDigest signed1
              , _pOrig = _sigBody signed1
              , _pTimeStamp = Nothing}})
  it "Seq LogEntry" $ do
    leSeqDec <- leSeqDecoded
    theSeq <- leSeq
    leSeqDec `shouldBe` theSeq
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
  it "AppendEntries" $ do
    aerpc <- aeRPC
    aeSigned <- aeSignedRPC
    fromWire Nothing keySet aeSigned
      `shouldBe`
        (Right $ aerpc {
            _aeProvenance = ReceivedMsg
              { _pDig = _sigDigest aeSigned
              , _pOrig = _sigBody aeSigned
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

privKeyLeader, privKeyFollower, privKeyClient :: Ed25519.PrivateKey
privKeyLeader = fromMaybe (error "bad key") $
  Ed25519.importPrivate "\204m\223Uo|\211.\144\131\&5Xmlyd$\165T\148\&11P\142m\249\253$\216\232\220c"
privKeyFollower = fromMaybe (error "bad key") $
  Ed25519.importPrivate "$%\181\214\b\138\246(5\181%\199\186\185\t!\NUL\253'\t\ENQ\212^\236O\SOP\217\ACK\EOT\170<"
privKeyClient = fromMaybe (error "bad key") $
  Ed25519.importPrivate "8H\r\198a;\US\249\233b\DLE\211nWy\176\193\STX\236\SUB\151\206\152\tm\205\205\234(\CAN\254\181"

pubKeyLeader, pubKeyFollower, pubKeyClient :: Ed25519.PublicKey
pubKeyLeader = fromMaybe (error "bad key") $
  Ed25519.importPublic "f\t\167y\197\140\&2c.L\209;E\181\146\157\226\137\155$\GS(\189\215\SUB\199\r\158\224\FS\190|"
pubKeyFollower = fromMaybe (error "bad key") $
  Ed25519.importPublic "\187\182\129\&4\139\197s\175Sc!\237\&8L \164J7u\184;\CANiC\DLE\243\ESC\206\249\SYN\189\ACK"
pubKeyClient = fromMaybe (error "bad key") $
  Ed25519.importPublic "@*\228W(^\231\193\134\239\254s\ETBN\208\RS\137\201\208,bEk\213\221\185#\152\&7\237\234\DC1"

keySet :: KC.KeySet
keySet = KC.KeySet
  { KC._ksCluster = Map.fromList [ (_alias nodeIdLeader, pubKeyLeader),
                                   (_alias nodeIdFollower, pubKeyFollower) ] }

-- #####################################
-- Commands, with and without provenance
-- #####################################

mkTestCommand
  :: Ed25519.PublicKey
  -> Ed25519.PrivateKey
  -> Text
  -> Text
  -> IO (P.Command ByteString)
mkTestCommand pubKey privKey nonce cmdTxt = do
  let someScheme = P.toScheme P.ED25519
  let pubBS = P.PubBS (Ed25519.exportPublic pubKey)
  let privBS = P.PrivBS (Ed25519.exportPrivate privKey)
  case P.importKeyPair someScheme (Just pubBS) (privBS) of
    Left _ -> die "WireFormatSpec.mkTestCommand -- importKeyPair failed"
    Right someKP -> P.mkCommand [(someKP, [])] (Nothing :: Maybe Value) nonce Nothing (Exec (ExecMsg cmdTxt Null))

cmdRPC1, cmdRPC2 :: IO NewCmdRPC
cmdRPC1 = do
  cmd <- mkTestCommand pubKeyClient privKeyClient "nonce1" "(+ 1 2)"
  return $ NewCmdRPC
          { _newCmd =
              [encodeCommand $
                SmartContractCommand
                { _sccCmd = cmd
                , _sccPreProc = Unprocessed
                }]
          , _newProvenance = NewMsg }
cmdRPC2 = do
  cmd <- mkTestCommand pubKeyClient privKeyClient "nonce2" "(+ 3 4)"
  return $ NewCmdRPC
          { _newCmd =
              [encodeCommand $
                SmartContractCommand
                { _sccCmd = cmd
                , _sccPreProc = Unprocessed
                }]
          , _newProvenance = NewMsg }

cmdSignedRPC1, cmdSignedRPC2 :: IO SignedRPC
cmdSignedRPC1 = toWire nodeIdLeader pubKeyLeader privKeyLeader <$> cmdRPC1
cmdSignedRPC2 = toWire nodeIdFollower pubKeyFollower privKeyFollower <$> cmdRPC2

-- these are signed (received) provenance versions
cmdRPC1', cmdRPC2' :: IO Command
cmdRPC1' = either error (decodeCommand . head . _newCmd) . fromWire Nothing keySet <$> cmdSignedRPC1
cmdRPC2' = either error (decodeCommand . head . _newCmd) . fromWire Nothing keySet <$> cmdSignedRPC2

-- ########################################################
-- LogEntry(s) and Seq LogEntry with correct hashes.
-- LogEntry is not an RPC but is(are) nested in other RPCs.
-- Given this, they are handled differently (no provenance)
-- ########################################################
logEntry1, logEntry2 :: IO LogEntry
logEntry1 = do
  cmd1 <- cmdRPC1'
  return $ hashLogEntry Nothing $ LogEntry
    { _leTerm    = Term 0
    , _leLogIndex = 0
    , _leCommand = cmd1
    , _leHash    = P.pactHash "logEntry1"
    , _leCmdLatMetrics = Nothing
    }
logEntry2 = do
  cmd2 <- cmdRPC2'
  entry1 <- logEntry1
  return $ hashLogEntry (Just $ _leHash entry1) $ LogEntry
    { _leTerm    = Term 0
    , _leLogIndex = 1
    , _leCommand = cmd2
    , _leHash    = P.pactHash "logEntry2"
    , _leCmdLatMetrics = Nothing
    }

leSeq, leSeqDecoded :: IO LogEntries
leSeq = do
  entry1 <- logEntry1
  entry2 <- logEntry2
  return $ (\(Right v) -> v) $ checkLogEntries $ Map.fromList [(0,entry1),(1,entry2)]
leSeqDecoded = (\(Right v) -> v) . decodeLEWire Nothing <$> leWire

leWire :: IO [LEWire]
leWire = encodeLEWire <$> leSeq

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
aeRPC :: IO AppendEntries
aeRPC = do
  theSeq <- leSeq
  return $ AppendEntries
    { _aeTerm        = Term 0
    , _leaderId      = nodeIdLeader
    , _prevLogIndex  = LogIndex (-1)
    , _prevLogTerm   = Term 0
    , _aeEntries     = theSeq
    , _aeQuorumVotes = rvrRPCSet'
    , _aeProvenance  = NewMsg
    }


aeSignedRPC :: IO SignedRPC
aeSignedRPC = toWire nodeIdLeader pubKeyLeader privKeyLeader <$> aeRPC


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
  , _aerHash       = P.pactHash "hello"
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
