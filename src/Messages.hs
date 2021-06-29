{-# LANGUAGE DuplicateRecordFields #-}
module Messages where

import Data.Text.Encoding
import Data.Text
import Data.ByteString.Lazy
-- import Data.ByteString (toLazy)

import Network.WebSockets
import Data.Aeson
import Control.Applicative
import Data.Time
import GHC.Generics

data MessageFromUser 
  = MyMessage MyMessage
  | MyPing Text
  | MyPong Text
  | MyClose Text
  deriving Generic

data MyMessage 
  = MyMessageIs Text
  | AcceptedMessages Int
  deriving Generic

newtype MyNameIs 
  = MyNameIs Text
  deriving Generic

instance FromJSON MyNameIs

instance ToJSON MyNameIs where

instance ToJSON MyMessage where

instance FromJSON MyMessage where

data MessageToUser
  = ServerMessage ServerMessage 
  | ServerPing Text
  | ServerPong Text
  | ServerClose Text
  deriving (Generic, Show)

data ServerMessage 
  = ServerConnected Integer 
  | ServerRegistered
  | ServerError Text
  | ServerNewMessages [UserMessage]
  | ServerUsersOnline UTCTime [User]
  deriving (Generic, Show)
  
data User = User 
  { name :: Text
  , sessionId :: Integer }
  deriving (Generic, Show)

instance FromJSON User
instance ToJSON User

instance FromJSON ServerMessage where

instance ToJSON ServerMessage where

data UserMessage = UserMessage 
  { name :: Text
  , text :: Text
  , timestamp :: UTCTime 
  , messageId :: Int
  , sessionId :: Integer }
  deriving (Generic, Show)

instance FromJSON UserMessage
instance ToJSON UserMessage

class FromMessage a where
  fromMessage :: Message -> Either Text a

class ToMessage a where
  toMessage :: a -> Message

bsToT :: ByteString -> Text
bsToT = decodeUtf8 . toStrict 

instance ToMessage ServerMessage where
  toMessage = toMessage . ServerMessage

instance ToMessage MessageToUser where
  toMessage (ServerMessage msg) = DataMessage False False False (Binary $ encode msg)
  toMessage (ServerPing msg) = ControlMessage (Ping $ encode msg)
  toMessage (ServerPong msg) = ControlMessage (Pong $ encode msg)
  toMessage (ServerClose msg) = ControlMessage (Close 1000 $ encode msg)

instance ToMessage MessageFromUser where
  toMessage (MyMessage msg) = toMessage msg
  toMessage (MyPing msg) = ControlMessage (Ping $ encode msg)
  toMessage (MyPong msg) = ControlMessage (Pong $ encode msg)
  toMessage (MyClose msg) = ControlMessage (Close 1000 $ encode msg)


instance ToMessage Message where
  toMessage = id

instance ToMessage MyMessage where
  toMessage m = DataMessage False False False (Binary $ encode m)

instance ToMessage MyNameIs where
  toMessage m = DataMessage False False False (Binary $ encode m)

instance FromMessage MessageFromUser where
  fromMessage (ControlMessage (Close _ msg)) = Right $ MyClose $ bsToT msg
  fromMessage (ControlMessage (Ping msg)) = Right $ MyPing $ bsToT msg
  fromMessage (ControlMessage (Pong msg)) = Right $ MyPong $ bsToT msg
  fromMessage (DataMessage _ _ _ (Binary msg)) = either (Left . Data.Text.pack) Right $ MyMessage <$> eitherDecode msg
  fromMessage (DataMessage _ _ _ (Text msg _)) = either (Left . Data.Text.pack) Right $ MyMessage <$> eitherDecode msg

instance FromMessage MyNameIs where
  fromMessage (DataMessage _ _ _ (Binary msg)) = either (Left . Data.Text.pack) Right $ MyNameIs <$> eitherDecode msg
  fromMessage (DataMessage _ _ _ (Text msg _)) = either (Left . Data.Text.pack) Right $ MyNameIs <$> eitherDecode msg
  fromMessage _ = Left "Failed to parse MyNameIs request"

instance FromMessage MessageToUser where
  fromMessage (ControlMessage (Close _ msg)) = Right $ ServerClose $ bsToT msg
  fromMessage (ControlMessage (Ping msg)) = Right $ ServerPing $ bsToT msg
  fromMessage (ControlMessage (Pong msg)) = Right $ ServerPong $ bsToT msg
  fromMessage (DataMessage _ _ _ (Binary msg)) = either (Left . Data.Text.pack) Right $ ServerMessage <$> eitherDecode msg
  fromMessage (DataMessage _ _ _ (Text msg _)) = either (Left . Data.Text.pack) Right $ ServerMessage <$> eitherDecode msg



