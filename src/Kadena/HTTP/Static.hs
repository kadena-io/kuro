{-# LANGUAGE OverloadedStrings #-}
module Kadena.HTTP.Static where


import Snap.Core
import Snap.Util.FileServe
import Data.ByteString

staticRoutes :: Bool -> [(ByteString,Snap ())]
staticRoutes False = []
staticRoutes True = [("/",serveDirectory "./static")]
