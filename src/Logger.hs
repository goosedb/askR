module Logger where

import Data.Time
import Data.Text (Text, pack, intercalate)
import qualified Data.Text.IO as TIO
import Data.Map (Map, foldMapWithKey, insert, delete)
import Control.Monad.IO.Class ( MonadIO (..) )
import Control.Concurrent.Chan
import Control.Concurrent
import Control.Monad (forever)
import AppState
import Messages

type WithLoggerCustom b l s m = (?logger :: Logger b l s m)

data Logger b l s m = Logger 
  { backendDataHandler :: b
  , putLogHandler :: b -> l -> s -> m () }

putLog :: WithLoggerCustom b l s m => l -> s -> m ()
putLog = let Logger {..} = ?logger in putLogHandler backendDataHandler

withLogger :: Logger b l s m -> (WithLoggerCustom b l s m => m a) -> m a
withLogger logger = let ?logger = logger in id

data DefaultBackend m = DefaultBackend
  { getTimeForLogger :: m UTCTime
  , labels :: Map Text Text
  , channel :: Chan Text }

data LogLevel 
  = Info
  | Debug
  | Warning
  | Error
  deriving Show

type WithLogger m = WithLoggerCustom (DefaultBackend m) LogLevel Text m

defaultBackend :: MonadIO m => m (DefaultBackend m)
defaultBackend = do
  chan <- liftIO newChan
  pure DefaultBackend
    { getTimeForLogger = liftIO getCurrentTime
    , labels = mempty
    , channel = chan }

defaultLogger :: MonadIO m => m (Logger (DefaultBackend m) LogLevel Text m)
defaultLogger = do
  backend@DefaultBackend { channel = chan } <- defaultBackend
  liftIO $ forkIO do 
    liftIO do forever do readChan chan >>= TIO.putStrLn
  pure Logger 
    { backendDataHandler = backend
    , putLogHandler = \DefaultBackend {..} lvl str -> do
      time <- pack . take 23 . show <$> getTimeForLogger
      let renderedLevel = " [" <> pack (show lvl) <> "]"
      let renderedLabels | null labels = mempty
                         | otherwise   = 
                           let rendered = intercalate "," $ foldMapWithKey 
                                  (\k v -> ["#" <> k <> "=" <> v]) labels
                           in " { " <> rendered <> " }" 
      let msg = time <> renderedLevel <> renderedLabels <> " " <> str
      liftIO $ writeChan channel msg
    }

withLabel :: (WithLogger m, Logged a) => Text -> a -> (WithLogger m => m b) -> m b
withLabel k v action = 
  let Logger {..} = ?logger in
  let DefaultBackend {..} = backendDataHandler in
  let ?logger = Logger { backendDataHandler = DefaultBackend { labels = insert k (toLog v) labels, .. } , .. } in action

withoutLabel :: WithLogger m => Text -> Text -> (WithLogger m => m a) -> m a
withoutLabel k v action = 
  let Logger {..} = ?logger in
  let DefaultBackend {..} = backendDataHandler in
  let ?logger = Logger { backendDataHandler = DefaultBackend { labels = delete k labels, .. } , .. } in action

class Logged a where
  toLog :: a -> Text
  
instance Logged Text where
  toLog = id

instance Logged Int where
  toLog = pack . show

instance Logged Integer where
  toLog = pack . show

instance Logged String where
  toLog = pack

instance Logged UserSession where
  toLog UserSession {..} = "UserSession#" <> toLog sessionId

instance Logged UserMessage where
  toLog UserMessage {..} = name .& "#" &. sessionId .& ": " &. text

instance Logged a => Logged [a] where
  toLog as = "[ " <> intercalate ", " (map toLog as) <> " ]"

(&.) :: (Logged a) => Text -> a -> Text
l &. r =  toLog l <> toLog r

(.&) :: (Logged a) => a -> Text -> Text
l .& r =  toLog l <> toLog r

(.&.) :: (Logged a, Logged b) => a -> b -> Text
l .&. r = toLog l <> toLog r

infixr 6 &.
infixr 6 .&
infixr 6 .&.
