{-# LANGUAGE OverloadedStrings #-}
module Main where

import Server
import Data.Text

main :: IO ()
main = do
  foo <- getLine
  if foo == "c" 
    then getLine >>= \s -> allH $ client . pack $ s
    else allH serverApp 
