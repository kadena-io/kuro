{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

module Apps.Juno.JsonTypes
    (commandResponseSuccess,commandResponseFailure
    ,cmdStatus2PollResult,cmdStatusError
    ,PollPayloadRequest(..),PollPayload(..),PollResponse(..),PollResult(..)
    ) where

import           Control.Monad (mzero)
import           Data.Aeson as JSON
import           Data.Aeson.Types (Options(..))
import qualified Data.Text as T
import           Data.Text.Encoding as E
import           Data.Text (Text)
import           GHC.Generics

import Juno.Types.Command
import Juno.Types.Base



data Digest = Digest { _hash :: Text, _key :: Text } deriving (Eq, Generic, Show)

instance ToJSON Digest where
    toJSON = genericToJSON $ defaultOptions { fieldLabelModifier = drop 1 }
instance FromJSON Digest where
    parseJSON  = genericParseJSON $ defaultOptions { fieldLabelModifier = drop 1 }


data CommandResponse = CommandResponse {
      _status :: Text
    , _cmdid :: Text
    , _message :: Text
    } deriving (Eq, Generic, Show)

instance ToJSON CommandResponse where
    toJSON = genericToJSON $ defaultOptions { fieldLabelModifier = drop 1 }
instance FromJSON CommandResponse where
    parseJSON = genericParseJSON $ defaultOptions { fieldLabelModifier = drop 1 }

commandResponseSuccess :: Text -> Text -> CommandResponse
commandResponseSuccess cid msg = CommandResponse "Success" cid msg

commandResponseFailure :: Text -> Text -> CommandResponse
commandResponseFailure cid msg = CommandResponse "Failure" cid msg

-- | Polling for commands
data PollPayload = PollPayload {
  _cmdids :: [Text]
  } deriving (Eq, Generic, Show)

instance ToJSON PollPayload where
  toJSON = genericToJSON $ defaultOptions { fieldLabelModifier = drop 1 }
instance FromJSON PollPayload where
  parseJSON = genericParseJSON $ defaultOptions { fieldLabelModifier = drop 1 }

data PollPayloadRequest = PollPayloadRequest {
  _pollPayload :: PollPayload,
  _pollDigest :: Digest
  } deriving (Eq, Generic, Show)

instance ToJSON PollPayloadRequest where
  toJSON (PollPayloadRequest payload' digest') = object ["payload" .= payload'
                                                        , "digest" .= digest']
instance FromJSON PollPayloadRequest where
  parseJSON (Object v) = PollPayloadRequest <$> v .: "payload"
                                            <*> v .: "digest"
  parseJSON _ = mzero

-- {
--  "results": [
--    {
--      "status": "PENDING",
--      "cmdid": "string",
--      "logidx": "string",
--      "message": "string",
--      "payload": {}
--    }
--  ]
-- }

data PollResult = PollResult
  { _pollStatus :: Text
  , _pollCmdId :: Text
  , _logidx :: Int
  , _pollMessage :: Text
  , _pollResPayload :: Text
  } deriving (Eq, Generic, Show, FromJSON)
instance ToJSON PollResult where
    toJSON (PollResult status cmdid logidx msg payload') =
      object [ "status" .= status
             , "cmdid" .= cmdid
             , "logidx" .= logidx
             , "message" .= msg
             , "payload" .= payload'
             ]

-- TODO: logindex, payload after Query/Observe Accounts is added.
cmdStatus2PollResult :: RequestId -> CommandStatus -> PollResult
cmdStatus2PollResult (RequestId rid) CmdSubmitted =
  PollResult{_pollStatus = "PENDING", _pollCmdId = toText rid, _logidx = -1, _pollMessage = "", _pollResPayload = ""}
cmdStatus2PollResult (RequestId rid) CmdAccepted =
  PollResult{_pollStatus = "PENDING", _pollCmdId = toText rid, _logidx = -1, _pollMessage = "", _pollResPayload = ""}
cmdStatus2PollResult (RequestId rid) (CmdApplied (CommandResult res) _) =
  PollResult{_pollStatus = "ACCEPTED", _pollCmdId = toText rid, _logidx = -1, _pollMessage = "", _pollResPayload = decodeUtf8 res}

cmdStatusError :: PollResult
cmdStatusError = PollResult
  { _pollStatus = "ERROR"
  , _pollCmdId = "errorID"
  , _logidx = -1
  , _pollMessage = "nothing to say"
  , _pollResPayload = "no payload"
  }

toText :: Show a => a -> Text
toText = T.pack . show

data PollResponse = PollResponse { _results :: [PollResult] }
  deriving (Eq, Generic, Show)

instance ToJSON PollResponse where
  toJSON = genericToJSON $ defaultOptions { fieldLabelModifier = drop 1 }
