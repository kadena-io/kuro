module Apps.Juno.Server
  ( main
  ) where

import Juno.Spec.Simple

-- | Runs a 'Raft nt String String mt'.
main :: IO ()
main = runServer
