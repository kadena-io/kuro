{-# LANGUAGE OverloadedStrings #-}

module LogSpec where

import Test.Hspec

import Control.Lens
import Data.Maybe (fromJust)
import qualified Data.Map.Strict as Map

import Kadena.Types
import Kadena.Log.LogApi hiding (keySet)
-- import Kadena.Log.Types hiding (keySet)

{-
spec :: Spec
spec = do
  describe "LogEntries manipulation functions" testLogEntries
  describe "PersistedLogEntries manipulation functions" testPersistedLogEntries
  --describe "LogState instance" testLogState

testLogEntries:: Spec
testLogEntries= do
  sampleLogsFoo <- return $ mkLogEntries 0 10
  sampleLogsBar <- return $ mkLogEntriesBar 0 10
  it "lesNull True" $
    (lesNull lesEmpty) `shouldBe` True
  it "lesNull False" $
    (lesNull sampleLogsFoo) `shouldBe` False
  it "lesCnt" $
    (lesCnt $ mkLogEntries 0 10) `shouldBe` 11
  it "lesMinEntry" $
    (lesMinEntry sampleLogsFoo) `shouldBe` (Just $ logEntry 0)
  it "lesMaxEntry" $
    (lesMaxEntry sampleLogsFoo) `shouldBe` (Just $ logEntry 10)
  it "lesMinIndex" $
    (lesMinIndex sampleLogsFoo) `shouldBe` (Just 0)
  it "lesMaxIndex" $
    (lesMaxIndex sampleLogsFoo) `shouldBe` (Just 10)
  it "lesGetSection #1" $
    (lesGetSection Nothing (Just 8) sampleLogsFoo) `shouldBe` (mkLogEntries 0 8)
  it "lesGetSection #2" $
    (lesGetSection (Just 1) (Just 8) sampleLogsFoo) `shouldBe` (mkLogEntries 1 8)
  it "lesGetSection #3" $
    (lesGetSection (Just 2) Nothing sampleLogsFoo) `shouldBe` (mkLogEntries 2 10)
  it "lesUnion" $
    (lesUnion sampleLogsFoo sampleLogsBar) `shouldBe` sampleLogsFoo
  it "lesUnions" $
    (lesUnions [sampleLogsFoo,sampleLogsBar]) `shouldBe` sampleLogsFoo

testPersistedLogEntries :: Spec
testPersistedLogEntries = do
  sampleLogs0 <- return $ mkLogEntries 0 9
  sampleLogs1 <- return $ mkLogEntries 10 19
  sampleLogs2 <- return $ mkLogEntries 20 29
  sampleLogs3 <- return $ mkLogEntries 30 39
  samplePLogs <- return $
    PersistedLogEntries $ Map.fromList [(LogIndex 0, sampleLogs0),(LogIndex 10, sampleLogs1),(LogIndex 20, sampleLogs2)]
  samplePLogs2 <- return $
    PersistedLogEntries $ Map.fromList [(LogIndex 0, sampleLogs0),(LogIndex 10, sampleLogs1),(LogIndex 20, sampleLogs2),(LogIndex 30, sampleLogs3)]
  it "plesNull True" $
    (plesNull plesEmpty) `shouldBe` True
  it "plesNull False" $
    (plesNull samplePLogs) `shouldBe` False
  it "plesCnt" $
    (plesCnt $ samplePLogs) `shouldBe` 30
  it "plesMinEntry" $
    (plesMinEntry samplePLogs) `shouldBe` (Just $ logEntry 0)
  it "plesMaxEntry" $
    (plesMaxEntry samplePLogs) `shouldBe` (Just $ logEntry 29)
  it "plesMinIndex" $
    (plesMinIndex samplePLogs) `shouldBe` (Just 0)
  it "plesMaxIndex" $
    (plesMaxIndex samplePLogs) `shouldBe` (Just 29)
  it "plesGetSection #1" $
    (Map.keysSet $ _logEntries $ plesGetSection Nothing (Just 28) samplePLogs) `shouldBe` (Map.keysSet $ _logEntries $ mkLogEntries 0 28)
  it "plesGetSection #2" $
    (Map.keysSet $ _logEntries $ plesGetSection (Just 1) (Just 28) samplePLogs) `shouldBe` (Map.keysSet $ _logEntries $ mkLogEntries 1 28)
  it "plesGetSection #3" $
    (Map.keysSet $ _logEntries $ plesGetSection (Just 2) Nothing samplePLogs) `shouldBe` (Map.keysSet $ _logEntries $ mkLogEntries 2 29)
  it "plesGetSection #4" $
    (Map.keysSet $ _logEntries $ plesGetSection (Just 10) Nothing samplePLogs) `shouldBe` (Map.keysSet $ _logEntries $ mkLogEntries 10 29)
  it "plesGetSection #5" $
    (Map.keysSet $ _logEntries $ plesGetSection (Just 10) (Just 19) samplePLogs) `shouldBe` (Map.keysSet $ _logEntries $ mkLogEntries 10 19)
  it "plesGetSection #6" $
    (Map.keysSet $ _logEntries $ plesGetSection Nothing (Just 19) samplePLogs) `shouldBe` (Map.keysSet $ _logEntries $ mkLogEntries 0 19)
  it "plesAddNew" $
    (plesAddNew sampleLogs3 samplePLogs) `shouldBe` samplePLogs2

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
  { _ksCluster = Map.fromList [(_alias nodeIdLeader, pubKeyLeader),
                               (_alias nodeIdFollower, pubKeyFollower)]
  , _ksClient = Map.fromList [(_alias nodeIdClient, pubKeyClient)] }

cmdRPC0, cmdRPC1 :: Int -> Command
cmdRPC0 i = Command
  { _cmdEntry = CommandEntry "CreateAccount foo"
  , _cmdClientId = _alias nodeIdClient
  , _cmdRequestId = RequestId $ show i
  , _cmdCryptoVerified = Valid
  , _cmdProvenance = NewMsg }
cmdRPC1 i = Command
  { _cmdEntry = CommandEntry "CreateAccount bar"
  , _cmdClientId = _alias nodeIdClient
  , _cmdRequestId = RequestId $ show i
  , _cmdCryptoVerified = Valid
  , _cmdProvenance = NewMsg }

-- these are signed (received) provenance versions
cmdRPC0', cmdRPC1' :: Int -> Command
cmdRPC0' i = (\(Right v) -> v) $ fromWire Nothing keySet $ toWire nodeIdClient pubKeyClient privKeyClient $ cmdRPC0 i
cmdRPC1' i = (\(Right v) -> v) $ fromWire Nothing keySet $ toWire nodeIdClient pubKeyClient privKeyClient $ cmdRPC1 i

-- ########################################################
-- LogEntry(s) and Seq LogEntry with correct hashes.
-- LogEntry is not an RPC but is(are) nested in other RPCs.
-- Given this, they are handled differently (no provenance)
-- ########################################################
logEntry, logEntryBar :: Int -> LogEntry
logEntry i = LogEntry
  { _leTerm    = Term 0
  , _leLogIndex = LogIndex i
  , _leCommand = cmdRPC0' i
  , _leHash    = ""
  }
logEntryBar i = LogEntry
  { _leTerm    = Term 0
  , _leLogIndex = LogIndex i
  , _leCommand = cmdRPC1' i
  , _leHash    = ""
  }

mkLogEntries, mkLogEntriesBar :: Int -> Int -> LogEntries
mkLogEntries stIdx endIdx = either error id $ checkLogEntries $ Map.fromList $ fmap (\i -> (fromIntegral i, logEntry i)) [stIdx..endIdx]
mkLogEntriesBar stIdx endIdx = either error id $ checkLogEntries $ Map.fromList $ fmap (\i -> (fromIntegral i, logEntryBar i)) [stIdx..endIdx]

-- ###############
-- ## Log State ##
-- ###############

_testLogState :: Spec
_testLogState = do
  -- Leaving this here for now: the switch over to RWST makes this a bit trickier
  it "updateLogs NewLogEntries" $
    True `shouldBe` True -- (updateLogs (ULNew volatileNLE) steadyState) `shouldBe` volatileState
  it "updateLogs ULReplicate Clean" $
    True `shouldBe` True -- (updateLogs (ULReplicate volatileReplicate) steadyState) `shouldBe` volatileState
  it "updateLogs ULReplicate Overwrite #1" $
    True `shouldBe` True -- (updateLogs (ULReplicate volatileReplicate) overwriteState1) `shouldBe` volatileState
  it "updateLogs ULReplicate Overwrite #2" $
    True `shouldBe` True -- (updateLogs (ULReplicate volatileReplicate) overwriteState2) `shouldBe` volatileState
  it "updateLogs ULReplicate Exercise `alreadyStored` #1" $
    True `shouldBe` True -- (updateLogs (ULReplicate hackedVolReplicate0) volatileState) `shouldBe` volatileState
  it "updateLogs ULReplicate Exercise `alreadyStored` #2" $
    True `shouldBe` True -- (updateLogs (ULReplicate hackedVolReplicate1) volatileState) `shouldBe` volatileState

steadyState :: LogState
steadyState = LogState
    { _lsVolatileLogEntries = lesEmpty
    , _lsPersistedLogEntries = PersistedLogEntries $ Map.fromList [(0,sampleLogs0), (10,sampleLogs1), (20, sampleLogs2)]
    , _lsLastApplied = LogIndex 29
    , _lsLastLogIndex = LogIndex 29
    , _lsLastLogHash = _leHash $ fromJust $ lesMaxEntry sampleLogs2
    , _lsNextLogIndex = LogIndex 30
    , _lsCommitIndex = LogIndex 29
    , _lsLastPersisted = LogIndex 29
    , _lsLastInMemory = Just $ LogIndex 0
    , _lsLastCryptoVerified = LogIndex 29
    , _lsLastLogTerm = Term 0
    }
  where
    sampleLogs0 = updateLogEntriesHashes Nothing $ mkLogEntries 0 9
    sampleLogs1 = updateLogEntriesHashes (lesMaxEntry sampleLogs0) $ mkLogEntries 10 19
    sampleLogs2 = updateLogEntriesHashes (lesMaxEntry sampleLogs1) $ mkLogEntries 20 29

volatileReplicate :: ReplicateLogEntries
volatileReplicate = (\(Right v) -> v) $ toReplicateLogEntries (LogIndex 29) $ mkLogEntries 30 39

-- hacked because I'm changing the CommandEntry without touching the pOrig which is what is used for hashing.
-- Thus, the hashes should be the same thus testing that addLogEntriesAt will not replicated entries already replicated
hackLogEntriesCmds :: LogEntries -> LogEntries
hackLogEntriesCmds (LogEntries les) = LogEntries $ f <$> les
  where
    f l = set (leCommand.cmdEntry) (CommandEntry "CreateAccount bar") l

hackedVolReplicate0, hackedVolReplicate1 :: ReplicateLogEntries
hackedVolReplicate0 = (\(Right v) -> v) $ toReplicateLogEntries (LogIndex 29) $ hackLogEntriesCmds $ mkLogEntries 30 39
hackedVolReplicate1 = (\(Right v) -> v) $ toReplicateLogEntries (LogIndex 29) $ hackLogEntriesCmds $ mkLogEntries 30 32

volatileNLE :: NewLogEntries
volatileNLE = NewLogEntries
  { _nleTerm = 0
  , _nleEntries = NleEntries $ (\l -> l ^. _2.leCommand) <$> Map.toAscList (_logEntries $ mkLogEntries 30 39)
  }

volatileState :: LogState
volatileState = LogState
    { _lsVolatileLogEntries = sampleLogs3
    , _lsPersistedLogEntries = PersistedLogEntries $ Map.fromList [(0,sampleLogs0), (10,sampleLogs1), (20, sampleLogs2)]
    , _lsLastApplied = LogIndex 29
    , _lsLastLogIndex = LogIndex 39
    , _lsLastLogHash = _leHash $ fromJust $ lesMaxEntry sampleLogs3
    , _lsNextLogIndex = LogIndex 40
    , _lsCommitIndex = LogIndex 29
    , _lsLastPersisted = LogIndex 29
    , _lsLastInMemory = Just $ LogIndex 0
    , _lsLastCryptoVerified = LogIndex 29
    , _lsLastLogTerm = Term 0
    }
  where
    sampleLogs0 = updateLogEntriesHashes Nothing $ mkLogEntries 0 9
    sampleLogs1 = updateLogEntriesHashes (lesMaxEntry sampleLogs0) $ mkLogEntries 10 19
    sampleLogs2 = updateLogEntriesHashes (lesMaxEntry sampleLogs1) $ mkLogEntries 20 29
    sampleLogs3 = updateLogEntriesHashes (lesMaxEntry sampleLogs2) $ mkLogEntries 30 39

overwriteState1 :: LogState
overwriteState1 = LogState
    { _lsVolatileLogEntries = sampleLogs3
    , _lsPersistedLogEntries = PersistedLogEntries $ Map.fromList [(0,sampleLogs0), (10,sampleLogs1), (20, sampleLogs2)]
    , _lsLastApplied = LogIndex 29
    , _lsLastLogIndex = LogIndex 39
    , _lsLastLogHash = _leHash $ fromJust $ lesMaxEntry sampleLogs3
    , _lsNextLogIndex = LogIndex 40
    , _lsCommitIndex = LogIndex 29
    , _lsLastPersisted = LogIndex 29
    , _lsLastInMemory = Just $ LogIndex 0
    , _lsLastCryptoVerified = LogIndex 29
    , _lsLastLogTerm = Term 0
    }
  where
    sampleLogs0 = updateLogEntriesHashes Nothing $ mkLogEntries 0 9
    sampleLogs1 = updateLogEntriesHashes (lesMaxEntry sampleLogs0) $ mkLogEntries 10 19
    sampleLogs2 = updateLogEntriesHashes (lesMaxEntry sampleLogs1) $ mkLogEntries 20 29
    sampleLogs3 = updateLogEntriesHashes (lesMaxEntry sampleLogs2) $ mkLogEntriesBar 30 39

overwriteState2 :: LogState
overwriteState2 = LogState
    { _lsVolatileLogEntries = sampleLogs3
    , _lsPersistedLogEntries = PersistedLogEntries $ Map.fromList [(0,sampleLogs0), (10,sampleLogs1), (20, sampleLogs2)]
    , _lsLastApplied = LogIndex 29
    , _lsLastLogIndex = LogIndex 39
    , _lsLastLogHash = _leHash $ fromJust $ lesMaxEntry sampleLogs3
    , _lsNextLogIndex = LogIndex 40
    , _lsCommitIndex = LogIndex 29
    , _lsLastPersisted = LogIndex 29
    , _lsLastInMemory = Just $ LogIndex 0
    , _lsLastCryptoVerified = LogIndex 29
    , _lsLastLogTerm = Term 0
    }
  where
    sampleLogs0 = updateLogEntriesHashes Nothing $ mkLogEntries 0 9
    sampleLogs1 = updateLogEntriesHashes (lesMaxEntry sampleLogs0) $ mkLogEntries 10 19
    sampleLogs2 = updateLogEntriesHashes (lesMaxEntry sampleLogs1) $ mkLogEntries 20 29
    sampleLogs3 = updateLogEntriesHashes (lesMaxEntry sampleLogs2) $ mkLogEntriesBar 30 49
-}
