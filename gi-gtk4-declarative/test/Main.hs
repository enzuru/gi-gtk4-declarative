module Main where

import           Control.Concurrent
import           Control.Monad
import qualified GI.GLib                       as GLib
import qualified GI.Gtk                        as Gtk
import           System.Environment
import           System.Exit
import           System.IO

import qualified GI.Gtk.Declarative.AfterCreatedTest
                                               as AfterCreatedTest
import qualified GI.Gtk.Declarative.BinTest    as BinTest
import qualified GI.Gtk.Declarative.ContainerTest
                                               as ContainerTest
import qualified GI.Gtk.Declarative.CustomWidgetTest
                                               as CustomWidget
import qualified GI.Gtk.Declarative.EventControllerTest
                                               as EventControllerTest
import qualified GI.Gtk.Declarative.MenuModelTest
                                               as MenuModelTest
import qualified GI.Gtk.Declarative.ModelViewTest
                                               as ModelViewTest
import qualified GI.Gtk.Declarative.PatchTest  as PatchTest
import qualified GI.Gtk.Declarative.ReferenceTest
                                               as ReferenceTest
import qualified GI.Gtk.Declarative.ReplaceTest
                                               as ReplaceTest
import qualified GI.Gtk.Declarative.AttributeTest
                                               as AttributeTest
import qualified GI.Gtk.Declarative.SlotTest   as SlotTest


main :: IO ()
main = do
  -- A nested X server has no GL worth speaking of, and the tests run
  -- under one.
  setUnlessSet "GDK_BACKEND" "x11"
  setUnlessSet "GSK_RENDERER" "cairo"

  Gtk.init
  mainLoop <- GLib.mainLoopNew Nothing False
  pass     <- newEmptyMVar
  -- The tests run off the main loop's thread and talk to GTK through
  -- 'GI.Gtk.Declarative.TestUtils.runUI'.
  _        <- forkOS $ do
    results <-
      sequence
        [ CustomWidget.tests
        , PatchTest.tests
        , BinTest.tests
        , ContainerTest.tests
        , MenuModelTest.tests
        , EventControllerTest.tests
        , ReplaceTest.tests
        , AttributeTest.tests
        , SlotTest.tests
        , ReferenceTest.tests
        , ModelViewTest.tests
        , AfterCreatedTest.tests
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
