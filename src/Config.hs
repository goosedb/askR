module Config where

type WithConfigLoader m = (?configLoader :: ConfigLoader m)

newtype ConfigLoader m = ConfigLoader
  { loadConfigHandler :: m Config }

type WithConfig = (?config :: Config)

newtype Config = Config
  { server :: ServerConfig
  }

data ServerConfig = ServerConfig { port :: Int, persistedMessages :: Int }

withConfigLoader :: ConfigLoader m -> (WithConfigLoader m => m a) -> m a
withConfigLoader cfgl = let ?configLoader = cfgl in id

withConfig :: Config -> (WithConfig => a) -> a
withConfig cfg = let ?config = cfg in id

withLoadedConfig :: (Monad m, WithConfigLoader m) => (WithConfig => m a) -> m a
withLoadedConfig action = 
  let ConfigLoader {..} = ?configLoader 
  in loadConfigHandler >>= \c -> withConfig c action

fromConfigGet :: WithConfig => (Config -> a) -> a
fromConfigGet f = f ?config 
