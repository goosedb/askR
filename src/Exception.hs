module Exception where

import Control.Exception ( Exception )
import UnliftIO

type WithExceptions m = (?exceptionHandler :: ExceptionHandler m)

data ExceptionHandler m = ExceptionHandler
  { throwHandler :: forall e a. Exception e => e -> m a
  , catchHandler :: forall e a. Exception e => m a -> (e -> m a) -> m a }

throw :: (WithExceptions m, Exception e) => e -> m a
throw = throwHandler ?exceptionHandler

catch :: (WithExceptions m, Exception e) => m a -> (e -> m a) -> m a
catch = catchHandler ?exceptionHandler

withExceptionHandler :: ExceptionHandler m -> (WithExceptions m => m a) -> m a
withExceptionHandler h action = let ?exceptionHandler = h in action

withIOExceptionHandler ::  MonadUnliftIO m => (WithExceptions m => m a) -> m a
withIOExceptionHandler = withExceptionHandler 
  ExceptionHandler 
    { throwHandler = liftIO . throwIO
    , catchHandler = UnliftIO.catch
    }