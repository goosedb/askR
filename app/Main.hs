{-# LANGUAGE OverloadedStrings #-}
module Main where

import Server

main :: IO ()
main = allH $ client "Danil"
