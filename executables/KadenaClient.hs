module Main where

import qualified Apps.Kadena.Client as App
import System.Environment
import Kadena.Command.PactSqlLite
main :: IO ()
main = do
  as <- getArgs
  case as of ["bench"] -> _bench
             _ -> App.main
