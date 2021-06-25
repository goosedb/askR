{-# LANGUAGE TupleSections #-}
module AppState where

import Network.WebSockets ( Connection )
import Control.Monad.IO.Class
import Control.Concurrent.MVar
import UnliftIO (MonadUnliftIO (..), toIO)
import Data.Functor
import Data.Text ( Text ) 
import Data.Time
import GHC.Generics
import Data.Aeson

type WithAppStateController m = (?appStateController :: AppStateController m) 

data AppStateController m = AppStateController
  { withAppStateController :: forall a. (AppState -> m a) -> m a
  , modifyAppStateController :: forall a. (AppState -> m (AppState, a)) -> m a }

data AppState = AppState 
  { userSessions   :: [UserSession]
  , nextSession    :: Integer
  , currentMessage :: Int
  , messages       :: [Message]
  }

data Message = Message
  { user      :: UserSession
  , text      :: Text
  , timestamp :: UTCTime
  , messageId :: Int }

data UserSession = UserSession
  { sessionId        :: Integer
  , connection       :: Connection
  , name             :: Text
  , acceptedMessage  :: Int }

withNewAppStateController :: forall m a. MonadUnliftIO m => (WithAppStateController m => m a) -> m a
withNewAppStateController action = do
  state <- liftIO $ newMVar $ AppState [] 0 0 []
  let ?appStateController = AppStateController 
        { withAppStateController = \f -> withRunInIO \unlift -> do withMVar state (unlift . f)
        , modifyAppStateController = \f -> withRunInIO \unlift -> do modifyMVar  state (unlift . f)
        }
    in action

getAppState :: (WithAppStateController m, Applicative m) => m AppState
getAppState = 
  let AppStateController {..} = ?appStateController
  in withAppStateController pure

modifyAppState :: (WithAppStateController m, Applicative m) => (AppState -> m (AppState, a)) -> m a
modifyAppState f = 
  let AppStateController {..} = ?appStateController
  in modifyAppStateController f

modifyAppState_ :: (WithAppStateController m, Applicative m) => (AppState -> m AppState) -> m ()
modifyAppState_ f = 
  let AppStateController {..} = ?appStateController
  in modifyAppStateController (fmap (,()) . f)


withAppState :: WithAppStateController m => (AppState -> m a) -> m a
withAppState f =  
  let AppStateController {..} = ?appStateController
  in withAppStateController f