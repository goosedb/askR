module Websockets where

import Network.WebSockets
import Data.Aeson
import Data.Text
import Control.Monad.IO.Class
import Messages

type WithWebSocketProvider m = (?websocketProvider :: WebsocketProvider m)

data WebsocketProvider m = WebsocketProvider
  { acceptConnectionHandler :: PendingConnection -> m Connection
  , sendMessageHandler :: forall a. ToMessage a => Connection -> a -> m ()
  , receiveMessageHandler :: forall a. FromMessage a => Connection -> m (Either Text a)
  , closeConnectionHandler :: Connection -> Text -> m () }

withWebSocketProvider :: WebsocketProvider m -> (WithWebSocketProvider m => m a) -> m a
withWebSocketProvider provider action = let ?websocketProvider = provider in action

acceptConnection :: WithWebSocketProvider m => PendingConnection -> m Connection 
acceptConnection = acceptConnectionHandler ?websocketProvider

sendMessage :: (WithWebSocketProvider m, ToMessage a) => Connection -> a -> m () 
sendMessage = sendMessageHandler ?websocketProvider

receiveMessage :: (WithWebSocketProvider m, FromMessage a) => Connection -> m (Either Text a)
receiveMessage = receiveMessageHandler ?websocketProvider

closeConnection :: WithWebSocketProvider m => Connection -> Text -> m ()
closeConnection = closeConnectionHandler ?websocketProvider

defaultWebSocketProvider :: MonadIO m => WebsocketProvider m
defaultWebSocketProvider = WebsocketProvider
  { acceptConnectionHandler = liftIO . acceptRequest
  , sendMessageHandler = \conn -> liftIO . send conn . toMessage
  , receiveMessageHandler = fmap fromMessage  . liftIO . receive
  , closeConnectionHandler = \conn -> liftIO . sendClose conn }
