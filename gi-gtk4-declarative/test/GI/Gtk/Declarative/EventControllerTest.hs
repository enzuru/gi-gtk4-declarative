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
import           Data.Maybe                     ( catMaybes )
import           Data.Text                      ( Text )
import           Data.Word                      ( Word32 )
import qualified GI.Gio                        as Gio
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.EventController
                                                ( addOwnedController )
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

-- | A widget keeps its controller for as long as it lives.
--
-- An application cancels and subscribes again on every event, so a
-- controller that came off with its subscription would be a new
-- controller after every event. What the subscription owns is the
-- handler behind the controller.
prop_controllers_do_not_pile_up = withTests 1 . property $ do
  (baseline, counts, sameEachTime) <- evalIO $ runUI $ bracket (Gtk.new Gtk.Window []) Gtk.windowDestroy $ \window -> do
    let markup :: Widget Event
        markup = widget Gtk.Label [onClickPressed (\_nPress _x _y -> Clicked)]
    state    <- create markup
    label    <- someStateWidget state
    Gtk.windowSetChild window (Just label)
    baseline' <- countControllers label
    -- Three rounds of the subscribe and cancel an application does.
    rounds    <- forM [1 :: Int, 2, 3] $ \_round -> do
      sub    <- subscribe markup state (const (pure ()))
      during <- countControllers label
      found  <- controllersOf label
      cancel sub
      after  <- countControllers label
      pure ((during, after), found)
    let counts' = map fst rounds
        found'  = map snd rounds
    pure (baseline', counts', allSame found')
  counts === replicate 3 (baseline + 1, baseline + 1)
  sameEachTime === True

-- | The controller is the same object after a patch, which is what a
-- gesture needs: a 'Gtk.GestureClick' counts the presses of a double
-- click, and a gesture that was put back counts from none, so the
-- second click of every double click would arrive as a first.
prop_a_controller_survives_a_patch = withTests 1 . property $ do
  (same, count) <- evalIO $ runUI $ bracket (Gtk.new Gtk.Window []) Gtk.windowDestroy $ \window -> do
    let clickable :: Text -> Widget Event
        clickable text = widget
          Gtk.Label
          [#label := text, onClickPressed (\_nPress _x _y -> Clicked)]
    state  <- create (clickable "before")
    label  <- someStateWidget state
    Gtk.windowSetChild window (Just label)
    -- A label comes with a controller of GTK's own, so what is counted
    -- here is what the library added on top of it.
    baseline <- countControllers label
    sub    <- subscribe (clickable "before") state (const (pure ()))
    before' <- controllersOf label
    cancel sub
    -- What an application does between two events: patch, then
    -- subscribe to the new markup.
    state' <- patch' state (clickable "before") (clickable "after")
    sub'   <- subscribe (clickable "after") state' (const (pure ()))
    after' <- controllersOf label
    cancel sub'
    pure (after' == before', fromIntegral (length after') - baseline)
  same === True
  count === 1

-- | A controller the markup no longer asks for is taken off the
-- widget, rather than left there counting nothing.
prop_a_controller_that_goes_away_is_taken_off = withTests 1 . property $ do
  (withController, without) <- evalIO $ runUI $ bracket (Gtk.new Gtk.Window []) Gtk.windowDestroy $ \window -> do
    let clickable :: Widget Event
        clickable = widget Gtk.Label [onClickPressed (\_nPress _x _y -> Clicked)]
        plain :: Widget Event
        plain = widget Gtk.Label []
    state    <- create clickable
    label    <- someStateWidget state
    Gtk.windowSetChild window (Just label)
    -- A label comes with a controller of GTK's own, so what is counted
    -- here is what the library added on top of it.
    baseline <- countControllers label
    sub      <- subscribe clickable state (const (pure ()))
    during   <- countControllers label
    cancel sub
    state'   <- patch' state clickable plain
    sub'     <- subscribe plain state' (const (pure ()))
    after    <- countControllers label
    cancel sub'
    pure (during - baseline, after - baseline)
  withController === 1
  without === 0

-- | A slot holds one kind of controller. When the attributes ask for
-- another kind in the same place, the controller that is there goes
-- and the new one takes its place, rather than both being on the
-- widget or the old one being read as the new one's type.
prop_a_slot_that_is_asked_for_another_kind_is_filled_again =
  withTests 1 . property $ do
    (added, clicks) <- evalIO $ runUI $ bracket (Gtk.new Gtk.Window []) Gtk.windowDestroy $ \window -> do
      let focused :: Widget Event
          focused = widget Gtk.Entry [onFocusEnter Focused]
          clicked :: Widget Event
          clicked = widget Gtk.Entry [onClickPressed (\_n _x _y -> Clicked)]
      state         <- create focused
      entry         <- someStateWidget state
      Gtk.windowSetChild window (Just entry)
      baseline      <- countControllers entry
      baselineClick <- countClickGestures entry
      sub           <- subscribe focused state (const (pure ()))
      cancel sub
      state'        <- patch' state focused clicked
      sub'          <- subscribe clicked state' (const (pure ()))
      after         <- countControllers entry
      afterClick    <- countClickGestures entry
      cancel sub'
      pure (after - baseline, afterClick - baselineClick)
    added === 1
    clicks === 1

-- | Cancelling stops the events, even though the controller stays.
prop_a_cancelled_subscription_stops_emitting = withTests 1 . property $ do
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
    _   <- Gtk.widgetGrabFocus second

    sub <- subscribe markup state (atomically . writeTBQueue received)
    cancel sub
    _   <- Gtk.widgetGrabFocus first
    _   <- Gtk.widgetGrabFocus second
    atomically (flushTBQueue received)
  events === []

-- | A controller added by hand can be kept.
--
-- A widget takes a controller over when it is given one, so the value
-- that went in is nobody's afterwards, and using it again is what the
-- bindings warn about. This is the way a custom widget adds one and
-- still has a reference to work with.
prop_a_controller_added_by_hand_can_be_kept = withTests 1 . property $ do
  (added, names) <- evalIO $ runUI $ bracket (Gtk.new Gtk.Window []) Gtk.windowDestroy $ \window -> do
    area <- Gtk.new Gtk.DrawingArea []
    Gtk.windowSetChild window (Just area)
    widget'  <- Gtk.toWidget area
    baseline <- countControllers widget'
    gesture  <- Gtk.gestureClickNew
    kept     <- addOwnedController area gesture
    -- Both of these read the value that came back, which is the whole
    -- point of it coming back.
    Gtk.eventControllerSetName kept (Just "kept by hand")
    _     <- Gtk.on kept #pressed (\_nPress _x _y -> pure ())
    after <- countControllers widget'
    found <- traverse Gtk.eventControllerGetName =<< controllersOf widget'
    pure (after - baseline, found)
  added === 1
  names === [Just "kept by hand"]

-- | Whether every round found the same controllers.
allSame :: Eq a => [a] -> Bool
allSame []             = True
allSame (first : rest) = all (== first) rest

-- | How many of the widget's controllers are click gestures.
countClickGestures :: Gtk.Widget -> IO Word32
countClickGestures widget' = do
  controllers <- controllersOf widget'
  gestures    <- traverse (Gtk.castTo Gtk.GestureClick) controllers
  pure (fromIntegral (length (catMaybes gestures)))

controllersOf :: Gtk.Widget -> IO [Gtk.EventController]
controllersOf widget' = do
  controllers <- Gtk.widgetObserveControllers widget'
  count       <- Gio.listModelGetNItems controllers
  items       <- forM [0 .. count - 1] (Gio.listModelGetItem controllers)
  traverse (Gtk.unsafeCastTo Gtk.EventController) (catMaybes items)

countControllers :: Gtk.Widget -> IO Word32
countControllers widget' =
  Gtk.widgetObserveControllers widget' >>= Gio.listModelGetNItems

-- * Test collection

tests :: IO Bool
tests = checkParallel $$(discover)
