{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}

{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module GI.Gtk.Declarative.CustomWidgetTest where

import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception.Safe
import           Control.Monad                  ( replicateM_ )
import           Control.Monad.IO.Class
import           Data.Function                  ( (&) )
import qualified Data.HashSet                  as HashSet
import qualified Data.Text                     as Text
import           Data.Vector                    ( Vector )
import qualified GI.GObject                    as GI
import qualified GI.Gtk                        as Gtk

import           Hedgehog
import qualified Hedgehog.Gen                  as Gen
import qualified Hedgehog.Range                as Range

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.State

import           GI.Gtk.Declarative.TestUtils

prop_sets_the_button_label = property $ do
  start       <- forAll (Gen.int (Range.linear 0 10))
  toggles     <- forAll (Gen.int (Range.linear 0 10))

  buttonLabel <- runUI . bracket (Gtk.new Gtk.Window []) Gtk.windowDestroy $ \window ->
    do
      let markup = testWidget [] start
      first <- create markup
      btn   <- someStateWidget first >>= Gtk.unsafeCastTo Gtk.ToggleButton & liftIO
      Gtk.windowSetChild window (Just btn)
      sub <- subscribe markup first (const (pure ()))
      toggleTimes btn toggles
      cancel sub
      Gtk.get btn #label

  let expectedLabel = Just (Text.pack (show (start + toggles)))
  expectedLabel === buttonLabel

prop_emits_correct_number_of_toggle_events = property $ do
  start   <- forAll (Gen.int (Range.linear 0 10))
  toggles <- forAll (Gen.int (Range.linear 0 10))

  values  <- liftIO (newTBQueueIO (fromIntegral (max 1 toggles)))
  runUI . bracket (Gtk.new Gtk.Window []) Gtk.windowDestroy $ \window -> do
    let markup = testWidget [] start
    first <- create markup
    btn   <- someStateWidget first >>= Gtk.unsafeCastTo Gtk.ToggleButton & liftIO
    Gtk.windowSetChild window (Just btn)
    sub <- subscribe markup first (atomically . writeTBQueue values)
    toggleTimes btn toggles
    cancel sub

  let expectedValues = take toggles [succ start ..]
  actualValues <- liftIO (atomically (flushTBQueue values))
  expectedValues === actualValues

prop_sets_classes = property $ do
  let genClasses =
        Gen.list (Range.linear 0 5) (Gen.text (Range.linear 1 5) Gen.alphaNum)
  initialClasses                <- forAll genClasses
  finalClasses                  <- forAll genClasses

  -- Whatever classes GTK itself puts on a button of this kind. They
  -- are there before and after, and are not this library's doing.
  baseClasses                   <-
    runUI $ do
      btn <- Gtk.new Gtk.ToggleButton [#label Gtk.:= "0"]
      Gtk.widgetGetCssClasses btn

  (classesBefore, classesAfter) <-
    runUI . bracket (Gtk.new Gtk.Window []) Gtk.windowDestroy $ \window -> do
      let markup1 = testWidget [classes initialClasses] 0
          markup2 = testWidget [classes finalClasses] 0
      first <- create markup1
      btn   <- liftIO
        (someStateWidget first >>= Gtk.unsafeCastTo Gtk.ToggleButton)
      Gtk.windowSetChild window (Just btn)
      beforeUpdate <- Gtk.widgetGetCssClasses btn
      _second      <- patch' first markup1 markup2
      afterUpdate  <- Gtk.widgetGetCssClasses btn
      pure (beforeUpdate, afterUpdate)

  HashSet.fromList (baseClasses <> initialClasses)
    === HashSet.fromList classesBefore
  HashSet.fromList (baseClasses <> finalClasses)
    === HashSet.fromList classesAfter

-- * Test widget and helpers

-- | A toggle button rather than a button: GTK 4 emits a button's
-- @clicked@ signal from a timeout that only runs while the button is on
-- screen, so a test cannot click one. Setting a toggle button's state
-- emits @toggled@ on the spot, which is the same thing for what these
-- tests are about.
testWidget :: Vector (Attribute Gtk.ToggleButton Int) -> Int -> Widget Int
testWidget customAttributes customParams = Widget (CustomWidget { .. })
 where
  customWidget = Gtk.ToggleButton
  customCreate start = do
    toggles <- newMVar start
    btn     <- Gtk.new Gtk.ToggleButton [#label Gtk.:= Text.pack (show start)]
    return (btn, toggles)

  customPatch
    :: Int -> Int -> MVar Int -> CustomPatch Gtk.ToggleButton (MVar Int)
  customPatch _ new toggles = CustomModify $ \btn -> do
    Gtk.set btn [#label Gtk.:= Text.pack (show new)]
    return toggles

  customSubscribe
    :: Int -> MVar Int -> Gtk.ToggleButton -> (Int -> IO ()) -> IO Subscription
  customSubscribe _params toggles btn cb = do
    h <- Gtk.on btn #toggled $ do
      current <- modifyMVar toggles $ \x -> pure (succ x, succ x)
      cb current
      Gtk.set btn [#label Gtk.:= Text.pack (show current)]
    return (fromCancellation (GI.signalHandlerDisconnect btn h))

-- | Toggle a button the given number of times. Each change of state
-- emits one @toggled@ signal.
toggleTimes :: MonadIO m => Gtk.ToggleButton -> Int -> m ()
toggleTimes btn n = replicateM_ n $ do
  active <- Gtk.toggleButtonGetActive btn
  Gtk.toggleButtonSetActive btn (not active)

-- * Test collection

tests :: IO Bool
tests = checkParallel $$(discover)
