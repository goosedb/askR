{-# LANGUAGE GADTs #-}
{-# LANGUAGE TupleSections #-}
module Server where

import Config
import Logger
import AppState
import UnliftIO
import qualified Data.Text.IO
import Data.Text.Encoding
import Data.ByteString.Lazy ( toStrict, putStr )
import Websockets
import Network.WebSockets (PendingConnection (pendingRequest), Connection, runServer, ConnectionException(..), sendDataMessage, runClient)
import Time
import Control.Concurrent
import Control.Monad
import Data.Text (Text, pack)
import Messages
import Data.Function
-- import Control.Exception

serverApp :: 
  ( MonadUnliftIO m
  , WithConfigLoader m
  , WithLogger m
  , WithAppStateController m
  , WithWebSocketProvider m
  , WithTimeProvider m
  ) => m ()
serverApp = withLoadedConfig do
  let serverPort = fromConfigGet (port . server)
  putLog Info $ "Starting server on port " &. serverPort
  withRunInIO \unlift -> do
    void $ liftIO $ forkIO $ unlift pingPong
    runServer "localhost" serverPort (unlift . acceptUser)

withProcessLabel :: WithLogger m => Text -> (WithLogger m => m a) -> m a
withProcessLabel = withLabel "process"

withSessionLabel :: WithLogger m => Integer -> (WithLogger m => m a) -> m a
withSessionLabel = withLabel "session"

acceptUser :: 
  ( MonadUnliftIO m
  , WithConfigLoader m
  , WithLogger m
  , WithAppStateController m
  , WithWebSocketProvider m
  , WithTimeProvider m
  ) => PendingConnection -> m ()
acceptUser pendingConnection = do
  connection <- acceptConnection pendingConnection
  userSession <- modifyAppState \AppState {..} -> pure 
    (AppState { nextSession = nextSession + 1, .. }, nextSession)
  withSessionLabel userSession do
    putLog Info "Accepted new connection"
    sendMessage connection (ServerConnected userSession)
    receiveMessage connection >>= \case
      Left err -> do
        let message = "Failed to register user: " &. err
        putLog Warning message
        sendMessage connection (ServerError message)
      Right (MyNameIs name) -> do
        let user = UserSession userSession connection name 0
        modifyAppState_ \AppState {..} -> pure AppState { userSessions = user : userSessions, .. }
        sendMessage connection ServerRegistered
        putLog Info $ "Registered user with name " &. name
        sendMessage connection (ServerPing "ping!")
        withRunInIO \unlift -> do
          void $ liftIO $ do
            forkIO $ unlift do 
              withSessionLabel userSession do 
                messageHandler user
                deleteUser user

messageHandler :: 
  ( MonadUnliftIO m
  , WithWebSocketProvider m
  , WithLogger m
  , WithTimeProvider m
  , WithAppStateController m
  , WithConfigLoader m
  ) => UserSession -> m ()
messageHandler session@UserSession {..} = 
  let handler = receiveMessage connection >>= \case
        Left err -> do
          let msg = "Failed to parse request: " &. err
          putLog Warning msg
          sendMessage connection (ServerError msg)
          handler
        Right parsed -> parsed & \case
          MyMessage (MyMessageIs msg) -> withLoadedConfig $ acceptMessage session msg >> broadcast >> handler
          MyMessage (AcceptedMessages lastMessage) -> updateUserState session lastMessage >> handler
          MyPing msg -> do
            putLog Debug $ "Client sent ping with message: " &. msg
            sendMessage connection (ServerPong "ok")
            handler
          MyPong msg -> do
            putLog Debug $ "Client sent pong with message: " &. msg
            handler
          MyClose msg -> do
            putLog Info $ "Client closed connection with message: " &. msg

      catchWebsocketError = \case 
        CloseRequest _ msg -> do
          putLog Info $ "Client closed connection with message: " &. decodeUtf8 (toStrict msg)
        ConnectionClosed -> do
          putLog Warning "Client closed connection unexpectedly"
        ParseException msg -> do
          putLog Warning $ "Client sent invalid request: " &. pack msg
          sendMessage connection (ServerError $ pack msg)
          handler
        UnicodeException msg -> do
          putLog Warning $ "Client sent invalid utf8: " &. pack msg
          sendMessage connection (ServerError $ pack msg)
          handler
          
      catchAny = \case 
        SomeException (pack . displayException -> err) -> do
          putLog Error $ "Catch exception: " &. err
          sendMessage connection (ServerShutOut $ "Internal server error. " <> err)

  in handler `catch` catchWebsocketError `catch` catchAny
        
acceptMessage :: 
  ( Monad m
  , WithAppStateController m
  , WithTimeProvider m
  , WithLogger m
  , WithConfig
  ) => UserSession -> Text -> m ()
acceptMessage user@UserSession {..} rawMessage = do 
  time <- getTime
  putLog Info "Accepted message"
  putLog Debug $ "Message: " &.rawMessage
  modifyAppState_ \AppState {..} -> do
    let message = Message user rawMessage time (currentMessage + 1)
    pure AppState 
      { messages = take (fromConfigGet (persistedMessages . server)) $ message : messages
      , currentMessage = currentMessage + 1
      , .. }

deleteUser :: (Monad m, WithAppStateController m, WithLogger m) => UserSession -> m ()
deleteUser UserSession { sessionId = session } = do
  modifyAppState_ \AppState {..} -> 
    pure AppState { userSessions = filter (is session .  AppState.sessionId) userSessions, .. }
  putLog Info "User disconnected"
  where is = (==)

broadcast :: (Monad m, WithWebSocketProvider m, WithAppStateController m, WithLogger m) => m ()
broadcast = do
  AppState {..} <- getAppState 
  forM_ userSessions \user@UserSession { sessionId = _, ..} -> do
    let howManyMessageToSend = currentMessage - acceptedMessage
    let messageToSend = map (\Message {..} -> UserMessage { sessionId = AppState.sessionId user, ..}) $ take howManyMessageToSend messages
    putLog Info $ "Sending " &. howManyMessageToSend .& " messages to " &. user
    putLog Debug $ "Messages: " &. messageToSend
    sendMessage connection $ ServerNewMessages messageToSend

updateUserState :: (Monad m, WithAppStateController m, WithLogger m) => UserSession -> Int -> m ()
updateUserState UserSession { sessionId = currentSession, ..} lastMessage = do
  modifyAppState_ \AppState {..} -> pure AppState { userSessions = map update userSessions, .. }
  putLog Debug $ "Last message set to " &. lastMessage
  where
    update user@UserSession {..} = if sessionId == currentSession 
      then UserSession { acceptedMessage = lastMessage, .. }
      else user

pingPong :: (MonadIO m, WithAppStateController m, WithWebSocketProvider m, WithLogger m) => m ()
pingPong = forever do
  AppState {..} <- getAppState 
  forM_ userSessions \UserSession {..} -> 
    sendMessage connection (ServerPing "ping!")
  putLog Debug "Pinged all users"
  liftIO $ threadDelay 10000000

client :: WithWebSocketProvider IO => Text -> IO ()
client name = runClient "localhost" 5002 "" \conn -> do
  sendMessage conn (MyNameIs name)
  forkIO $ forever $ receiveMessage conn >>= \case
      Right (ServerPing msg) -> do
        print msg
        sendMessage conn (MyPong "pong")
      Right (a :: MessageToUser) -> do print a
      Left e -> print e 
  forever do
    msg <- getLine 
    putStrLn msg
    sendMessage conn (MyMessageIs $ pack msg)
  

allH :: (( WithConfigLoader IO
  , WithLogger IO
  , WithAppStateController IO
  , WithWebSocketProvider IO
  , WithTimeProvider IO
  ) => IO a) -> IO a
allH a = do
  logger <- defaultLogger 
  withConfigLoader (ConfigLoader (pure $ Config $ ServerConfig 5002 10))
    $ withNewAppStateController 
    $ withWebSocketProvider defaultWebSocketProvider 
    $ withLogger logger
    $ withDefaultTimeProvider a
