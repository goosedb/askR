{-# LANGUAGE OverloadedStrings #-}
module Main where

import Server
-- import Data.Text
-- import Control.Monad
-- import Control.Concurrent
import Client

main :: IO ()
main = Client.client -- Server.allH Server.serverApp