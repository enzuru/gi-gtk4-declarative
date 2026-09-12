{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for event controllers.
--
-- GTK 4 gives a widget its keys, pointer, and gestures through
-- controller objects, and there is no way to synthesise a key press or
-- a click from code. Moving the keyboard focus is a function call,
-- though, so the focus controller is the one that can be driven here,
-- and it is the same path through the library that all of them take.
module GI.Gtk.Declarative.EventControllerTest where

import           Control.Concurrent.STM
import           Control.Exception.Safe         ( bracket )
import           Control.Monad                  ( forM )
import           Data.Word                      ( Word32 )
import qualified GI.Gio                        as Gio
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.TestUtils

data Event = Focused | Unfocused | Clicked
  deriving (Eq, Show)

-- | Two entries, the first of which reports when it gains and loses
-- the keyboard focus. Moving the focus to it and away again is what a
-- person would do with the mouse or the tab key.
prop_focus_controller_emits_events = withTests 1 . property $ do
  events <- evalIO $ runUI $ bracket (Gtk.new Gtk.Window []) Gtk.windowDestroy $ \window -> do
    received <- newTBQueueIO 10
    let markup :: Widget Event
        markup = container
          Gtk.Box
          []
          [ BoxChild defaultBoxChildProperties
            $ widget Gtk.Entry [onFocusEnter Focused, onFocusLeave Unfocused]
          , BoxChild defaultBoxChildProperties (widget Gtk.Entry [])
          ]
    state <- create markup
    box   <- someStateWidget state
    Gtk.windowSetChild window (Just box)
    Gtk.windowPresent window

    Just first  <- Gtk.widgetGetFirstChild box
    Just second <- Gtk.widgetGetNextSibling first
    -- Park the focus on the other entry, so that what follows does not
    -- depend on where GTK put it when the window opened.
    _   <- Gtk.widgetGrabFocus second

    sub <- subscribe markup state (atomically . writeTBQueue received)
    _   <- Gtk.widgetGrabFocus first
    _   <- Gtk.widgetGrabFocus second
    cancel sub
    atomically (flushTBQueue received)
  events === [Focused, Unfocused]

-- | Subscribing adds the controller to the widget, and cancelling
-- takes it off again. Rendering an application patches and resubscribes
-- on every event, so a controller that outlived its subscription would
-- pile up.
prop_controllers_do_not_pile_up = withTests 1 . property $ do
  (baseline, counts) <- evalIO $ runUI $ bracket (Gtk.new Gtk.Window []) Gtk.windowDestroy $ \window -> do
    let markup :: Widget Event
        markup = widget Gtk.Label [onClickPressed (\_nPress _x _y -> Clicked)]
    state    <- create markup
    label    <- someStateWidget state
    Gtk.windowSetChild window (Just label)
    baseline' <- countControllers label
    -- Three rounds of the subscribe and cancel an application does.
    counts'   <- forM [1 :: Int, 2, 3] $ \_round -> do
      sub    <- subscribe markup state (const (pure ()))
      during <- countControllers label
      cancel sub
      after  <- countControllers label
      pure (during, after)
    pure (baseline', counts')
  counts === replicate 3 (baseline + 1, baseline)

countControllers :: Gtk.Widget -> IO Word32
countControllers widget' =
  Gtk.widgetObserveControllers widget' >>= Gio.listModelGetNItems

-- * Test collection

tests :: IO Bool
tests = checkParallel $$(discover)
