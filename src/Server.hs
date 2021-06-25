{-# LANGUAGE GADTs #-}
{-# LANGUAGE TupleSections #-}
module Server where

import Config
    ( fromConfigGet,
      withLoadedConfig,
      ServerConfig(port, persistedMessages),
      Config(server),
      WithConfigLoader,
      WithConfig )
import Logger
    ( (.&),
      withLabel,
      (&.),
      putLog,
      WithLogger,
      LogLevel(Warning, Error, Info, Debug) )
import AppState
    ( modifyAppState_,
      modifyAppState,
      getAppState,
      WithAppStateController,
      Message(Message, messageId, timestamp, text, user),
      UserSession(..),
      AppState(AppState, messages, currentMessage, nextSession,
               userSessions) )
import UnliftIO
    ( MonadIO(..),
      Exception(displayException),
      SomeException(SomeException),
      MonadUnliftIO(..) )
import qualified Data.Text.IO
import Data.Text.Encoding ( decodeUtf8 )
import Data.ByteString.Lazy ( toStrict, putStr )
import Websockets
    ( receiveMessage,
      sendMessage,
      acceptConnection,
      WithWebSocketProvider )
import Network.WebSockets (PendingConnection (pendingRequest), Connection, runServer, ConnectionException(..), sendDataMessage, runClient)
import Time ( getTime, WithTimeProvider )
import Control.Monad ( forever, forM_, void )
import Data.Text (Text, pack)
import Messages
    ( UserMessage(UserMessage, sessionId, name, messageId, timestamp,
                  text),
      MyMessage(AcceptedMessages, MyMessageIs),
      MessageFromUser(MyClose, MyMessage, MyPing, MyPong),
      MessageToUser(ServerPing, ServerPong, ServerClose),
      MyNameIs(MyNameIs),
      ToMessage,
      ServerMessage(ServerNewMessages, ServerConnected, ServerRegistered,
                    ServerError) )
import Exception ( throw, catch, WithExceptions )
import Thread ( delay, fork, WithThreading )
import Control.Lens ( (&), (%~) )
import Data.Generics.Labels()

serverApp :: 
  ( MonadUnliftIO m
  , WithThreading m
  , WithExceptions m
  , WithConfigLoader m
  , WithLogger m
  , WithAppStateController m
  , WithWebSocketProvider m
  , WithTimeProvider m
  ) => m ()
serverApp = withLoadedConfig do
  let serverPort = fromConfigGet (port . server)
  putLog Info $ "Starting server on port " &. serverPort
  void $ fork pingPong
  withRunInIO \unlift -> runServer "localhost" serverPort (unlift . acceptUser)

withProcessLabel :: WithLogger m => Text -> (WithLogger m => m a) -> m a
withProcessLabel = withLabel "process"

withSessionLabel :: WithLogger m => Integer -> (WithLogger m => m a) -> m a
withSessionLabel = withLabel "session"

acceptUser :: 
  ( Monad m
  , WithExceptions m
  , WithConfigLoader m
  , WithLogger m
  , WithAppStateController m
  , WithWebSocketProvider m
  , WithTimeProvider m
  ) => PendingConnection -> m ()
acceptUser pendingConnection = do
  connection <- acceptConnection pendingConnection
  userSession <- modifyAppState \s@AppState {..} -> pure 
    (s & #nextSession %~ (+ 1), nextSession)
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
        modifyAppState_ $ pure . (#userSessions %~ (user :))
        sendMessage connection ServerRegistered
        putLog Info $ "Registered user with name " &. name
        withLabel "name" name do
          sendMessage connection (ServerPing "ping!")
          messageHandler user
          deleteUser user

messageHandler :: 
  ( Monad m
  , WithExceptions m
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
          MyMessage (MyMessageIs msg) -> withLoadedConfig do
            acceptMessage session msg >> broadcast >> handler
          MyMessage (AcceptedMessages lastMessage) -> do 
            updateUserState session lastMessage >> handler
          MyPing msg -> do
            putLog Debug $ "Client sent ping with message: " &. msg
            sendMessage connection (ServerPong "ok") >> handler
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
          sendMessage connection (ServerClose $ "Internal server error. " <> err)

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
  modifyAppState_ \appState@AppState {..} -> do
    let message = Message user rawMessage time (currentMessage + 1)
    let pm = fromConfigGet (persistedMessages . server)
    pure $ appState & 
      ( (#messages %~ (take pm . (message:)))
      . (#currentMessage %~ (+ 1)) )

deleteUser :: (Monad m, WithAppStateController m, WithLogger m) => UserSession -> m ()
deleteUser UserSession { sessionId = session } = do
  modifyAppState_ $ pure . (#userSessions %~ filter (is session . AppState.sessionId))
  putLog Info "User disconnected"
  where is = (==)

broadcast :: 
  ( Monad m
  , WithExceptions m
  , WithWebSocketProvider m
  , WithAppStateController m
  , WithLogger m
  ) => m ()
broadcast = do
  AppState {..} <- getAppState 
  forM_ userSessions \user@UserSession { name = _, .. } -> do
    let howManyMessageToSend = currentMessage - acceptedMessage
    let messageToSend = map (\Message {..} -> UserMessage 
          { sessionId = AppState.sessionId user
          , name = AppState.name user, ..} ) 
          $ take howManyMessageToSend messages
    putLog Info $ "Sending " &. howManyMessageToSend .& " messages to " &. user
    putLog Debug $ "Messages: " &. messageToSend
    sendMessageCloseProtected user (ServerNewMessages messageToSend)

updateUserState :: (Monad m, WithAppStateController m, WithLogger m) => UserSession -> Int -> m ()
updateUserState UserSession { sessionId = currentSession, ..} lastMessage = do
  modifyAppState_ $ pure . (#userSessions %~ map update)
  putLog Debug $ "Last message set to " &. lastMessage
  where
    update user@UserSession {..} = if sessionId == currentSession 
      then UserSession { acceptedMessage = lastMessage, .. }
      else user

pingPong :: 
  ( Monad m
  , WithThreading m
  , WithExceptions m
  , WithAppStateController m
  , WithWebSocketProvider m
  , WithLogger m
  ) => m ()
pingPong = forever do
  AppState {..} <- getAppState 
  forM_ userSessions \user@UserSession {..} -> 
    sendMessageCloseProtected user (ServerPing "ping!")
  putLog Debug "Pinged all users"
  delay 10000000

-- client :: (WithWebSocketProvider IO, WithLogger IO) => Text -> IO ()
-- client name = runClient "localhost" 5002 "" \conn -> do
--   sendMessage conn (MyNameIs name)
--   forkIO $ forever $ receiveMessage conn >>= \case
--       Right (ServerPing msg) -> do
--         putLog Debug $ "Server sent ping with " &. msg
--         sendMessage conn (MyPong "pong")
--       Right (ServerMessage (ServerConnected session)) -> do
--         putLog Info $ "Conneted with " &. session .& " session"
--       Right (ServerMessage ServerRegistered) -> do
--         putLog Info $ "Registered"
--       Right (ServerMessage (ServerError err)) -> do
--         putLog Warning $ "Server sent error: " &. err
--       Right (ServerClose msg) -> do
--         putLog Warning $ "Server shuted out: " &. msg
--       Right (ServerMessage (ServerNewMessages msgs)) -> do
--         putLog Info $ "Server sent new messages: " &. msgs
--         sendMessage conn (AcceptedMessages $ maximum $ map Messages.messageId msgs)
--       Right (ServerPong msg) -> do
--         putLog Debug $ "Server sent pong with " &. msg
--       Left e -> print e 
 
--   forever $ do  
--     msg <- getLine
--     sendMessage conn (MyMessageIs $ pack msg)

-- allH :: (( WithConfigLoader IO
--   , WithLogger IO
--   , WithAppStateController IO
--   , WithWebSocketProvider IO
--   , WithTimeProvider IO
--   ) => IO a) -> IO a
-- allH a = do
--   logger <- defaultLogger 
--   withConfigLoader (ConfigLoader (pure $ Config $ ServerConfig 5002 10))
--     $ withNewAppStateController 
--     $ withWebSocketProvider defaultWebSocketProvider 
--     $ withLogger logger
--     $ withDefaultTimeProvider a

sendMessageCloseProtected :: 
  ( Monad m
  , WithExceptions m
  , WithWebSocketProvider m
  , WithAppStateController m
  , WithLogger m
  , ToMessage a
  ) => UserSession 
    -> a 
    -> m () 
sendMessageCloseProtected user@UserSession {..} m = 
  sendMessage connection m `catch` ifConnectionClose user
  where
    ifConnectionClose user = \case 
      ConnectionClosed -> do 
        putLog Warning $ user .& " is closed"
        deleteUser user
      e -> throw e 
