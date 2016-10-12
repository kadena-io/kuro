{-# LANGUAGE OverloadedStrings #-}
module Kadena.HTTP.Static where


import Snap.Core
import Snap.Util.FileServe
import Data.ByteString

staticRoutes :: [(ByteString,Snap ())]
staticRoutes = [("monitor",monitor)]

monitor :: Snap ()
monitor = serveDirectory "monitor/public"
