{-# LANGUAGE GADTs #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE NumericUnderscores #-}
module Server where

import Config
import Logger
   
import AppState
 
import UnliftIO
    ( MonadIO(..),
      Exception(displayException),
      SomeException(SomeException),
      MonadUnliftIO(..) )
import qualified Data.Text.IO
import Data.Text.Encoding ( decodeUtf8 )
import Data.ByteString.Lazy ( toStrict, putStr )
import WebSockets 
import Network.WebSockets 
    ( PendingConnection (pendingRequest)
    , Connection
    , runServer
    , ConnectionException(..)
    , sendDataMessage
    , runClient )
import Time 
import Control.Monad ( forever, forM_, void, unless )
import Data.Text (Text, pack)
import Messages
import Exception 
import Thread
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
  withRunInIO \unlift -> runServer "0.0.0.0" serverPort (unlift . acceptUser)

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
          withLoadedAppState do 
            sendMessagesForUser user
          broadcast sendOnlineUsers
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
            acceptMessage session msg >> broadcast sendMessagesForUser >> handler
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
            deleteUser session >> broadcast sendOnlineUsers

      catchWebsocketError = \case 
        CloseRequest _ msg -> do
          putLog Info $ "Client closed connection with message: " &. decodeUtf8 (toStrict msg)
          deleteUser session >> broadcast sendOnlineUsers
        ConnectionClosed -> do
          putLog Warning "Client closed connection unexpectedly"
          deleteUser session >> broadcast sendOnlineUsers
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
  modifyAppState_ $ pure . (#userSessions %~ filter (not . is session . AppState.sessionId))
  AppState {..} <- loadAppState
  putLog Debug $ pack $ show userSessions
  putLog Info "User disconnected"
  where is = (==)

broadcast :: 
  ( Monad m
  , WithExceptions m
  , WithWebSocketProvider m
  , WithAppStateController m
  , WithLogger m
  ) => (WithAppState => UserSession -> m ()) ->  m ()
broadcast f = withLoadedAppState do
  let AppState {..} = getAppState 
  forM_ userSessions f

sendMessagesForUser :: 
  ( Monad m
  , WithExceptions m
  , WithWebSocketProvider m
  , WithAppState
  , WithAppStateController m
  , WithLogger m
  , WithTimeProvider m
  ) => UserSession -> m ()
sendMessagesForUser user@UserSession { name = _, .. } = do
    let AppState {..} = getAppState
    let howManyMessageToSend = currentMessage - acceptedMessage
    let messageToSend = map (\Message {..} -> UserMessage 
          { sessionId = AppState.sessionId user
          , name = AppState.name user, ..} ) 
          $ take howManyMessageToSend messages
    unless (null messageToSend) do
      putLog Info $ "Sending " &. howManyMessageToSend .& " messages to " &. user
      putLog Debug $ "Messages: " &. messageToSend
      sendMessageCloseProtected user (ServerNewMessages messageToSend)

sendOnlineUsers :: 
  ( Monad m
  , WithExceptions m
  , WithWebSocketProvider m
  , WithAppState
  , WithLogger m
  , WithTimeProvider m
  ) => UserSession -> m ()
sendOnlineUsers user@UserSession { connection } = do
  let AppState {..} = getAppState
  now <- getTime
  sendMessage connection $ ServerUsersOnline now $ map (\UserSession {..} -> User name sessionId) userSessions
  putLog Debug $ "Sent online users: " &. userSessions

updateUserState :: (Monad m, WithAppStateController m, WithLogger m) => UserSession -> Int -> m ()
updateUserState UserSession { sessionId = currentSession, ..} lastMessage = do
  modifyAppState_ $ pure . (#userSessions %~ map update)
  putLog Debug $ "Last message set to " &. lastMessage
  where
    update user@UserSession {..} = if sessionId == currentSession 
      then UserSession { acceptedMessage = max acceptedMessage lastMessage, .. }
      else user

pingPong :: 
  ( Monad m
  , WithThreading m
  , WithExceptions m
  , WithAppStateController m
  , WithWebSocketProvider m
  , WithLogger m
  , WithTimeProvider m
  ) => m ()
pingPong = forever do
  AppState {..} <- loadAppState 
  forM_ userSessions \user@UserSession {..} -> 
    sendMessageCloseProtected user (ServerPing "ping!")
  putLog Debug "Pinged all users"
  delay 10000000

client :: (WithWebSocketProvider IO, WithLogger IO, WithThreading IO) => Text -> IO ()
client name = runClient "localhost" 5003 "" \conn -> do
  sendMessage conn (MyNameIs name)
  fork $ forever $ receiveMessage conn >>= \case
      Right (ServerPing msg) -> do
        -- putLog Debug $ "Server sent ping with " &. msg
        sendMessage conn (MyPong "pong")
      Right (ServerMessage (ServerConnected session)) -> pure ()
        -- putLog Info $ "Conneted with " &. session .& " session"
      Right (ServerMessage ServerRegistered) -> pure ()
        -- putLog Info $ "Registered"
      Right (ServerMessage (ServerError err)) -> pure ()
        -- putLog Warning $ "Server sent error: " &. err
      Right (ServerClose msg) -> pure ()
        -- putLog Warning $ "Server shuted out: " &. msg
      Right (ServerMessage (ServerNewMessages msgs)) -> do
        -- putLog Info $ "Server sent new messages: " &. msgs
        sendMessage conn (AcceptedMessages $ maximum $ map Messages.messageId msgs)
      Right (ServerPong msg) -> pure ()
        -- putLog Debug $ "Server sent pong with " &. msg
      Right (ServerMessage (ServerUsersOnline _ _)) -> pure ()
      Left e -> print e 
 
  forever $ do  
    delay 1_000_000
    sendMessage conn (MyMessageIs "message")

allH :: (( WithConfigLoader IO
  , WithLogger IO
  , WithAppStateController IO
  , WithWebSocketProvider IO
  , WithTimeProvider IO
  , WithThreading IO
  , WithExceptions IO
  ) => IO a) -> IO a
allH a = do
  logger <- defaultLogger 
  withConfigLoader (ConfigLoader (pure $ Config $ ServerConfig 5003 100))
    $ withNewAppStateController 
    $ withWebSocketProvider defaultWebSocketProvider 
    $ withLogger logger
    $ withDefaultTimeProvider
    $ withIOThreadHandler
    $ withIOExceptionHandler a

sendMessageCloseProtected :: 
  ( Monad m
  , WithExceptions m
  , WithWebSocketProvider m
  , WithAppStateController m
  , WithLogger m
  , ToMessage a
  , WithTimeProvider m
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
        putLog Info "User deleted. Broadcastring.."
        broadcast sendOnlineUsers
      e -> throw e 
