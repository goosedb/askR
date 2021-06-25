module Time where

import Data.Time
import Control.Monad.IO.Class

type WithTimeProvider m = (?timeProvider :: TimeProvider m)

newtype TimeProvider m = TimeProvider
  { getTimeHandler :: m UTCTime }

withTime :: TimeProvider m -> (WithTimeProvider m => m a) -> m a
withTime tp action = let ?timeProvider = tp in action

defaultTimeProvider :: MonadIO m => TimeProvider m
defaultTimeProvider = TimeProvider (liftIO getCurrentTime)

withDefaultTimeProvider :: MonadIO m => (WithTimeProvider m => m a) -> m a
withDefaultTimeProvider = withTime defaultTimeProvider

getTime :: WithTimeProvider m => m UTCTime
getTime = getTimeHandler ?timeProvider