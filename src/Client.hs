{-# LANGUAGE DuplicateRecordFields #-}
module Client where

import Graphics.Vty
import Brick
import Brick.Forms
import Brick.Widgets.Border
import Brick
import Brick.Widgets.Core
import Brick.Widgets.Center
import Brick.Widgets.Edit
import Brick.BChan
import Messages
import Control.Lens
import GHC.Generics
import Data.Text ( Text, pack, unpack, chunksOf )
import qualified Data.Text as Text
import Data.Functor
import Data.Generics.Labels()
import Data.Maybe
import Network.WebSockets as WS
import Control.Monad.IO.Class
import WebSockets
import Control.Concurrent
import Control.Monad
import Text.Read
import Control.Exception
import Data.List
import Data.Function
import Data.Time

data ClientState = ClientState 
  { input :: BChan WS.Message 
  , output :: BChan Client.Event
  , window :: Window }
  deriving Generic

data Window 
  = Register RegisterState 
  | Chat ChatState 
  | Connection RegisterForm ThreadId
  | RegisterError RegisterForm Text

data ChatState = ChatState
  { messages      :: [UserMessage]
  , messageEditor :: Editor Text String 
  , lastOnlineReportUpdate :: Maybe UTCTime 
  , usersOnline :: [User]
  , name :: Text
  , sessionId :: Integer }
  deriving Generic

data AlertReason 
  = FatalError 
  | Warning

data Event 
  = Alert AlertReason Text 
  | Messages [UserMessage] 
  | Registered Integer
  | NotRegistered Text
  | OnlineUpdate UTCTime [User]

newtype RegisterState = RegisterState
  { editor :: Form RegisterForm Client.Event String }
  deriving Generic

data RegisterForm = RegisterForm 
  { name :: Text, host :: Text, port :: Int }
  deriving Generic

client :: IO ()
client =  withWebSocketProvider defaultWebSocketProvider do
  let vtyM = mkVty defaultConfig
  input <- newBChan 100
  output <- newBChan 100
  vty <- vtyM
  void $ customMain vty vtyM (Just output)
    App
      { appDraw = draw 
      , appChooseCursor = \_ -> listToMaybe
      , appHandleEvent = handleEvent
      , appStartEvent = pure
      , appAttrMap = const theMap }
    (ClientState input output $ Register $ RegisterState $ newRegisterForm emptyRegisterForm)

theMap :: AttrMap
theMap = attrMap defAttr []

sender :: (WithWebSocketProvider IO) => BChan WS.Message -> Connection -> IO ()
sender chan conn = forever $ liftIO (readBChan chan) >>= sendMessage conn

receiver :: (MonadIO m, WithWebSocketProvider m) => BChan Client.Event -> Connection -> m ()
receiver chan conn = do
  sessionIdStorage <- liftIO newEmptyMVar 
  forever do
    event <- receiveMessage conn >>= \case
          Left err -> pure $ Just $ Alert Warning "Message from server not parsed"
          Right msg -> msg & \case
            ServerMessage (ServerConnected session) -> liftIO $ putMVar sessionIdStorage session >> pure Nothing 
            ServerMessage ServerRegistered -> liftIO $ readMVar sessionIdStorage <&> Just . Registered
            ServerMessage (ServerError err) -> pure $  Just $ Alert FatalError err
            ServerMessage (ServerNewMessages msgs) -> do
              sendMessage conn (AcceptedMessages $ foldl max 0 $ map messageId msgs)
              pure $ Just $ Messages msgs
            ServerMessage (ServerUsersOnline timestamp users) -> pure $ Just $ OnlineUpdate timestamp users
            ServerPing msg -> Nothing <$ sendMessage conn (MyPing msg)
            ServerPong _ -> pure Nothing 
            ServerClose text -> pure $ Just $ Alert FatalError text
            
    maybe (pure ()) (liftIO . writeBChan chan) event

emptyEditor :: Editor Text String
emptyEditor = editorText "Editor" (Just 1) ""

handleEvent :: WithWebSocketProvider IO => ClientState -> BrickEvent String Client.Event -> EventM String (Next ClientState)
handleEvent s@ClientState { window = Connection form thread } (VtyEvent (EvKey KEsc [])) = do
  liftIO $ killThread thread
  continue s { window = Register $ RegisterState $ newRegisterForm form }
handleEvent s (VtyEvent (EvKey KEsc [])) = halt s
handleEvent s@ClientState { window = Connection RegisterForm {..} _ } (AppEvent (Registered sessionId)) = do
  liftIO $ appendFile "loglog.log" "here\n"
  continue s { window = Chat $ ChatState [] emptyEditor Nothing [] name sessionId }
handleEvent s@ClientState { window = Chat c@ChatState {..} } (AppEvent (OnlineUpdate timestamp users))
  | Nothing <- lastOnlineReportUpdate = 
    let newChatState = c & #lastOnlineReportUpdate ?~ timestamp & #usersOnline .~ users 
    in continue $ s & #window .~ Chat newChatState
  | Just t <- lastOnlineReportUpdate, t < timestamp = 
    let newChatState = c & #lastOnlineReportUpdate ?~ timestamp & #usersOnline .~ users 
    in continue $ s & #window .~ Chat newChatState
  | otherwise = continue s
handleEvent s@ClientState { window = Connection form _  , .. } (AppEvent (NotRegistered msg)) = do
  continue $ s { window = RegisterError form msg }
handleEvent s@ClientState { window = Register (RegisterState editor), .. } (VtyEvent (EvKey KEnter []))
  | allFieldsValid editor = do
    let form@RegisterForm {..} = formState editor
    threadId <- do
          let runClientInstance = do
                runClient (unpack host) port "" \conn -> do
                  forkIO $ receiver output conn
                  forkIO $ sender input conn
                  sendMessage conn (MyNameIs name)
                  forever $ threadDelay 300000000
          let handler = \(SomeException e) -> do
                writeBChan output (NotRegistered $ pack $ displayException e) 
          liftIO $ forkIO $ runClientInstance `catch` handler
    continue $ s { window = Connection form threadId }
  | otherwise             = continue s
handleEvent s@ClientState { window = Register (RegisterState editor) } e = 
  handleFormEvent e editor >>= continue . (s &) . (#window .~) . (Register . RegisterState)
handleEvent s@ClientState { window = RegisterError form _ } (VtyEvent (EvKey KEnter [])) = 
  continue s { window = Register $ RegisterState $ newRegisterForm form }
handleEvent s@ClientState{ window = Chat c@ChatState {..} } (AppEvent (Messages msgs)) = 
  let sortedMessages = sortBy (flip compare `Data.Function.on` messageId) msgs
      newChatState = c & #messages %~ (msgs <>) 
  in continue $ s & #window .~ Chat newChatState
handleEvent s@ClientState { window = Chat c@ChatState {..}, .. } (VtyEvent (EvKey KEnter []))
  | [msg] <- getEditContents messageEditor, Text.length msg > 0 = do
    liftIO (writeBChan input (toMessage $ MyMessageIs msg)) 
    let newChatState = c & #messageEditor .~ emptyEditor
    continue $ s & #window .~ Chat newChatState
handleEvent s@ClientState { window = Chat c@ChatState {..}, .. } (VtyEvent e) = do
  handleEditorEvent e messageEditor >>= \editor ->
    let newChatState = c & #messageEditor .~ editor
    in continue $ s & #window .~ Chat newChatState
handleEvent s _ = continue s

cleanBChan :: MonadIO m => BChan a -> m (BChan a)
cleanBChan chan = liftIO do
  fakeChan <- newBChan 1
  let pushToFake = writeBChan fakeChan ()
  let clean = 
        pushToFake >> readBChan2 fakeChan chan >>= \case
          Right _ -> clean
          Left _ -> pure ()
  clean >> pure chan

registerRequest :: BChan WS.Message -> Text -> EventM String ()
registerRequest chan name = liftIO $ writeBChan chan (toMessage $ MyNameIs name)

sendMessageRequest :: BChan WS.Message -> Text -> EventM String ()
sendMessageRequest chan name = liftIO $ writeBChan chan (toMessage $ MyMessageIs name)

newRegisterForm :: RegisterForm -> Form RegisterForm Client.Event String
newRegisterForm = 
  newForm 
      [ editField #name "FormName" (Just 1) id listToMaybe (txt . head) (str "name: " <+>)
      , editField #host "FormHost" (Just 1) id listToMaybe (txt . head) (str "host: " <+>) 
      , editField #port "FormPort" (Just 1) (pack . show) 
          (listToMaybe >=> (readMaybe . unpack) >=> (\p -> if p > 1024 && p < 65535 then Just p else Nothing)) 
          (txt . head) 
          (str "port: " <+>)
      ]

emptyRegisterForm :: RegisterForm
emptyRegisterForm = RegisterForm "Danil" "localhost" 5003


draw :: ClientState -> [Widget String]
draw ClientState { window = (Register (RegisterState editor)) } = 
  let RegisterForm {..} = formState editor
  in 
    [ center
      $ hLimit 30 $ vLimit 5
      $ borderWithLabel (txt "Enter your name") 
      $ center 
      $ padLeft (Pad 1) $ padRight (Pad 1)
      $ center 
      $ renderForm editor
    ]
draw ClientState { window = Connection _ _ } = [center $ str "Connection.."]
draw ClientState { window = RegisterError _ msg } = [ center $ borderWithLabel (str "Connection error") (vBox $ map txt $ chunksOf 50 msg) ]
draw ClientState { window = Chat ChatState {..} } = 
  let drawnMessages = vBox $ reverse $ take 30 $ map (\UserMessage {..} -> hBox 
        [ str (take 19 (show timestamp))
        , txt " "
        , txt name
        , txt "#"
        , str (show sessionId)
        , txt ": "
        , txt text] 
        ) messages
      drawnEditor = renderEditor (vBox . map txt) True messageEditor 
      drawnOnlineUsers = map (\User {..} -> hBox [txt name, txt "#", str (show sessionId) ] ) usersOnline
      drawnNick = hBox [txt name, txt "#", str (show sessionId), txt " > "]
  in [hBox [vBox [drawnMessages, border $ hBox [drawnNick, drawnEditor]], vBox drawnOnlineUsers ]]

