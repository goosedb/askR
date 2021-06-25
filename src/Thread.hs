module Thread where

import Control.Concurrent
import UnliftIO

type WithThreading m = (?threadingHandler :: ThreadingHandler m)

data ThreadingHandler m = ThreadingHandler
  { delayHandler :: Int -> m ()
  , forkHandler  :: forall a. m () -> m ThreadId }

withThreadingHandler :: ThreadingHandler m -> (WithThreading m => m a) -> m a
withThreadingHandler h action = let ?threadingHandler = h in action

withIOThreadHandler :: MonadUnliftIO m => (WithThreading m => m a) -> m a
withIOThreadHandler = withThreadingHandler 
  ThreadingHandler 
    { delayHandler = liftIO . threadDelay
    , forkHandler = \a -> withRunInIO \unlift -> forkIO (unlift a)
    }

fork :: WithThreading m => m () -> m ThreadId
fork = forkHandler ?threadingHandler

delay :: WithThreading m => Int -> m ()
delay = delayHandler ?threadingHandler