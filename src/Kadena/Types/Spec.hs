{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Spec
  ( Consensus
  , ConsensusSpec(..)
  , debugPrint, publishMetric, getTimestamp, random
  , viewConfig, readConfig, csTimerTarget, evidenceState, timeCache
  , ConsensusEnv(..), cfg, enqueueLogQuery, rs
  , enqueue, enqueueMultiple, dequeue, enqueueLater, killEnqueued
  , sendMessage, clientSendMsg, mResetLeaderNoFollowers, mPubConsensus
  , informEvidenceServiceOfElection, enqueueHistoryQuery
  , ConsensusState(..), initialConsensusState
  , csNodeRole, csTerm, csVotedFor, csLazyVote, csCurrentLeader, csIgnoreLeader
  , csTimerAsync, csYesVotes, csPotentialVotes, csLastCommitTime
  , csTimeSinceLastAER, csCmdBloomFilter, csInvalidCandidateResults
  , mkConsensusEnv
  , PublishedConsensus(..),pcLeader,pcRole,pcTerm,pcYesVotes
  , LazyVote(..), lvVoteFor, lvAllReceived
  , InvalidCandidateResults(..), icrMyReqVoteSig, icrNoVotes
  ) where

import Control.Concurrent (MVar, yield, threadDelay, tryPutMVar, tryTakeMVar)
import Control.Concurrent.Async as ASYNC
import Control.Concurrent.STM
import Control.Exception
import Control.Lens hiding (Index, (|>))
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.RWS.Strict (RWST)

import Data.BloomFilter (Bloom)
import qualified Data.BloomFilter as Bloom
import qualified Data.BloomFilter.Hash as BHash
import Data.Map (Map)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Thyme.Clock
import Data.Thyme.Time.Core ()
import System.Random (Random)

import Kadena.Types.Base
import Kadena.Config.TMVar
import Kadena.Types.Event
import Kadena.Types.Message
import Kadena.Types.Metric
import Kadena.Types.Comms
import Kadena.Types.Dispatch
import Kadena.Types.Sender (SenderServiceChannel, ServiceRequest')
import Kadena.Log.Types (QueryApi(..))
import Kadena.Types.History (History(..))
import Kadena.Types.Evidence (PublishedEvidenceState, Evidence(ClearConvincedNodes))
import Kadena.Util.Util (linkAsyncTrack')

data PublishedConsensus = PublishedConsensus
    { _pcLeader :: !(Maybe NodeId)
    , _pcRole :: !Role
    , _pcTerm :: !Term
    , _pcYesVotes :: !(Set RequestVoteResponse)
    }
makeLenses ''PublishedConsensus

data ConsensusSpec = ConsensusSpec
  {
    -- | Function to log a debug message (no newline).
    _debugPrint       :: !(String -> IO ())

  , _publishMetric    :: !(Metric -> IO ())

  , _getTimestamp     :: !(IO UTCTime)

  , _random           :: !(forall a . Random a => (a, a) -> IO a)

  }
makeLenses (''ConsensusSpec)

data InvalidCandidateResults = InvalidCandidateResults
  { _icrMyReqVoteSig :: !Signature
  , _icrNoVotes :: !(Set NodeId)
  } deriving (Show, Eq)
makeLenses ''InvalidCandidateResults

data LazyVote = LazyVote
  { _lvVoteFor :: !RequestVote
  , _lvAllReceived :: !(Map NodeId RequestVote)
  } deriving (Show, Eq)
makeLenses ''LazyVote

data ConsensusState = ConsensusState
  { _csNodeRole         :: !Role
  , _csTerm             :: !Term
  , _csVotedFor         :: !(Maybe NodeId)
  , _csLazyVote         :: !(Maybe LazyVote)
  , _csCurrentLeader    :: !(Maybe NodeId)
  , _csIgnoreLeader     :: !Bool
  , _csTimerAsync       :: !(Maybe (Async ()))
  , _csTimerTarget      :: !(MVar Event)
  , _csCmdBloomFilter   :: !(Bloom RequestKey)
  , _csYesVotes        :: !(Set RequestVoteResponse)
  , _csPotentialVotes  :: !(Set NodeId)
  , _csTimeSinceLastAER :: !Int
  -- used for metrics
  , _csLastCommitTime   :: !(Maybe UTCTime)
  -- used only during Candidate State
  , _csInvalidCandidateResults :: !(Maybe InvalidCandidateResults)
  }
makeLenses ''ConsensusState

initialConsensusState :: MVar Event -> ConsensusState
initialConsensusState timerTarget' = ConsensusState
{-role-}                Follower
{-term-}                startTerm
{-votedFor-}            Nothing
{-lazyVote-}            Nothing
{-currentLeader-}       Nothing
{-ignoreLeader-}        False
{-timerThread-}         Nothing
{-timerTarget-}         timerTarget'
{-cmdBloomFilter-}      (Bloom.empty (\(RequestKey (Hash k)) -> BHash.cheapHashes 30 k) 134217728)
{-cYesVotes-}           Set.empty
{-cPotentialVotes-}     Set.empty
{-timeSinceLastAER-}    0
{-lastCommitTime-}      Nothing
{-invalidCandidateResults-} Nothing

type Consensus = RWST ConsensusEnv () ConsensusState IO

data ConsensusEnv = ConsensusEnv
  { _cfg              :: !(GlobalConfigTMVar)
  , _enqueueLogQuery  :: !(QueryApi -> IO ())
  , _enqueueHistoryQuery :: !(History -> IO ())
  , _rs               :: !ConsensusSpec
  , _sendMessage      :: !(ServiceRequest' -> IO ())
  , _enqueue          :: !(Event -> IO ())
  , _enqueueMultiple  :: !([Event] -> IO ())
  , _enqueueLater     :: !(Int -> Event -> IO (Async ()))
  , _killEnqueued     :: !((Async ()) -> IO ())
  , _dequeue          :: !(IO Event)
  , _clientSendMsg    :: !(OutboundGeneral -> IO ())
  , _evidenceState    :: !(MVar PublishedEvidenceState)
  , _timeCache        :: !(IO UTCTime)
  , _mResetLeaderNoFollowers :: !(MVar ResetLeaderNoFollowersTimeout)
  , _informEvidenceServiceOfElection :: !(IO ())
  , _mPubConsensus    :: !(MVar PublishedConsensus)
  }
makeLenses ''ConsensusEnv

mkConsensusEnv
  :: GlobalConfigTMVar
  -> ConsensusSpec
  -> Dispatch
  -> MVar Event
  -> IO UTCTime
  -> MVar PublishedEvidenceState
  -> MVar ResetLeaderNoFollowersTimeout
  -> MVar PublishedConsensus
  -> ConsensusEnv
mkConsensusEnv conf' rSpec dispatch timerTarget' timeCache' mEs mResetLeaderNoFollowers' mPubConsensus' = ConsensusEnv
    { _cfg = conf'
    , _enqueueLogQuery = writeComm ls'
    , _enqueueHistoryQuery = writeComm hs'
    , _rs = rSpec
    , _sendMessage = sendMsg g'
    , _enqueue = writeComm ie' . ConsensusEvent
    , _enqueueMultiple = mapM_ (writeComm ie' . ConsensusEvent)
    , _enqueueLater = timerFn timerTarget'
    , _killEnqueued = catchCancel
    , _dequeue = _unConsensusEvent <$> readComm ie'
    , _clientSendMsg = writeComm cog'
    , _evidenceState = mEs
    , _timeCache = timeCache'
    , _mResetLeaderNoFollowers = mResetLeaderNoFollowers'
    , _informEvidenceServiceOfElection = writeComm ev' ClearConvincedNodes
    , _mPubConsensus = mPubConsensus'
    }
  where
    g' = dispatch ^. dispSenderService
    cog' = dispatch ^. dispOutboundGeneral
    ls' = dispatch ^. dispLogService
    hs' = dispatch ^. dispHistoryChannel
    ie' = dispatch ^. dispConsensusEvent
    ev' = dispatch ^. dispEvidence

timerFn :: (MVar Event) -> (Int -> Event -> IO (Async ()))
timerFn timerMVar =
  (\t event ->
    --MLN remove this, just for debugging
    catch ( do
      -- We want to clear it the instance that we reset the timer. Not doing this can cause a bug when
      -- there's an AE being processed when the thread fires, causing a needless election.As there is a
      -- single producer for this mvar + the consumer is single threaded + fires this fn this is safe.
      void $ tryTakeMVar timerMVar
      linkAsyncTrack' "ConsensusTimerThread" $ do
            threadDelay t
            b <- tryPutMVar timerMVar $! event
            unless b (putStrLn "Failed to update timer MVar")
            -- TODO: what if it's already taken?
      )
      (\e -> do
            let err = "Exception in timer thread: " ++ show (e :: SomeException)
            error err
      )
  )

catchCancel :: Async () -> IO ()
catchCancel asy = do
  _ <- waitAnyCancel [asy]
  return ()

sendMsg :: SenderServiceChannel -> ServiceRequest' -> IO ()
sendMsg outboxWrite og = do
  writeComm outboxWrite og
  yield

readConfig :: Consensus Config
readConfig = view cfg >>= fmap _gcConfig . liftIO . atomically . readTMVar

viewConfig :: Getting r Config r -> Consensus r
viewConfig l = do
  (c :: Config) <- view cfg >>= fmap _gcConfig . liftIO . atomically . readTMVar
  return $ view l c
