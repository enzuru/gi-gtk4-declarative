module Main where

import           Control.Concurrent
import           Control.Monad
import qualified GI.Adw                        as Adw
import qualified GI.GLib                       as GLib
import           System.Environment
import           System.Exit
import           System.IO

import qualified GI.Gtk.Declarative.Adwaita.BinTest
                                               as BinTest
import qualified GI.Gtk.Declarative.Adwaita.ContainerTest
                                               as ContainerTest
import qualified GI.Gtk.Declarative.Adwaita.ReferenceTest
                                               as ReferenceTest
import qualified GI.Gtk.Declarative.Adwaita.TabViewTest
                                               as TabViewTest

main :: IO ()
main = do
  -- A nested X server has no GL worth speaking of, and the tests run
  -- under one.
  setUnlessSet "GDK_BACKEND" "x11"
  setUnlessSet "GSK_RENDERER" "cairo"

  -- adw_init starts GTK as well, and libadwaita widgets want it: the
  -- style manager they read is one of the things it puts in place.
  Adw.init
  mainLoop <- GLib.mainLoopNew Nothing False
  pass     <- newEmptyMVar
  _        <- forkOS $ do
    results <- sequence
      [ BinTest.tests
      , ContainerTest.tests
      , ReferenceTest.tests
      , TabViewTest.tests
      ]
    GLib.mainLoopQuit mainLoop
    putMVar pass (and results)
  GLib.mainLoopRun mainLoop
  allPassed <- takeMVar pass
  unless allPassed $ do
    hPutStrLn stderr "Tests failed."
    exitFailure

setUnlessSet :: String -> String -> IO ()
setUnlessSet name value = do
  current <- lookupEnv name
  case current of
    Just _  -> pure ()
    Nothing -> setEnv name value
