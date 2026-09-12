{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for widget-valued properties.
--
-- A slot holds a declarative widget of its own, so it has to be
-- created, patched, subscribed to, and emptied like any other. These
-- check each of those through a window's title bar.
module GI.Gtk.Declarative.SlotTest where

import           Control.Concurrent.STM
import           Control.Exception.Safe         ( bracket )
import           Control.Monad                  ( foldM )
import           Data.Text                      ( Text )
import           Data.Vector                    ( Vector )
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Container.HeaderBar
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.TestUtils

data Event = Toggled
  deriving (Eq, Show)

windowWith :: Vector (Attribute Gtk.Window Event) -> Widget Event
windowWith attributes =
  bin Gtk.Window attributes (widget Gtk.Label [#label := ("body" :: Text)])

headerWith :: Text -> Widget Event
headerWith text =
  container Gtk.HeaderBar [] [headerBarTitle (widget Gtk.Label [#label := text])]

-- | Render each markup in turn, patching from one to the next, and
-- hand the window to the action.
renderWindows :: [Widget Event] -> (Gtk.Window -> IO a) -> IO a
renderWindows []             _ = fail "renderWindows: no markup to render"
renderWindows (first : rest) f = runUI $ do
  state  <- create first
  window <- Gtk.unsafeCastTo Gtk.Window =<< someStateWidget state
  result <- bracket (pure window) Gtk.windowDestroy $ \_ -> do
    _ <- foldM step (state, first) rest
    f window
  pure result
 where
  step (state, old) new = do
    state' <- patch' state old new
    pure (state', new)

titleOfTitlebar :: Gtk.Window -> IO (Maybe Text)
titleOfTitlebar window = do
  bar <- Gtk.windowGetTitlebar window
  case bar of
    Nothing -> pure Nothing
    Just b  -> do
      labels <- descendantLabels b
      pure (case labels of
        (text : _) -> Just text
        []         -> Nothing)

prop_a_slot_widget_is_put_in_place = withTests 1 . property $ do
  shown <- evalIO $ renderWindows [windowWith [titlebar (headerWith "first")]]
                                  titleOfTitlebar
  shown === Just "first"

-- | The header bar is modified rather than replaced, which is the
-- point of patching: the same object is still there afterwards, with
-- new contents.
prop_a_slot_widget_is_patched_in_place = withTests 1 . property $ do
  (before, after, sameBar) <- evalIO $ runUI $ do
    let first  = windowWith [titlebar (headerWith "first")]
        second = windowWith [titlebar (headerWith "second")]
    state     <- create first
    window    <- Gtk.unsafeCastTo Gtk.Window =<< someStateWidget state
    before'   <- titleOfTitlebar window
    barBefore <- Gtk.windowGetTitlebar window
    _         <- patch' state first second
    after'    <- titleOfTitlebar window
    barAfter  <- Gtk.windowGetTitlebar window
    Gtk.windowDestroy window
    pure (before', after', barBefore == barAfter)
  before === Just "first"
  after === Just "second"
  sameBar === True

prop_a_slot_is_emptied_when_it_goes_away = withTests 1 . property $ do
  labels <- evalIO $ renderWindows
    [windowWith [titlebar (headerWith "first")], windowWith []]
    (\window -> do
      bar <- Gtk.windowGetTitlebar window
      -- GTK puts a title bar of its own back when ours is taken away,
      -- so what matters is that ours is no longer there.
      maybe (pure []) descendantLabels bar
    )
  elem ("first" :: Text) labels === False

prop_a_slot_widget_emits_events = withTests 1 . property $ do
  events <- evalIO $ runUI $ do
    received <- newTBQueueIO 10
    let markup = windowWith
          [ titlebar
              (container
                Gtk.HeaderBar
                []
                [ headerBarTitle
                    (widget Gtk.ToggleButton [on #toggled Toggled])
                ]
              )
          ]
    state  <- create markup
    window <- Gtk.unsafeCastTo Gtk.Window =<< someStateWidget state
    sub    <- subscribe markup state (atomically . writeTBQueue received)
    bar    <- Gtk.windowGetTitlebar window
    button <- case bar of
      Nothing -> fail "no title bar"
      Just b  -> do
        title <- Gtk.headerBarGetTitleWidget =<< Gtk.unsafeCastTo Gtk.HeaderBar b
        maybe (fail "no title widget") (Gtk.unsafeCastTo Gtk.ToggleButton) title
    Gtk.toggleButtonSetActive button True
    cancel sub
    Gtk.windowDestroy window
    atomically (flushTBQueue received)
  events === [Toggled]

-- * Test collection

tests :: IO Bool
tests = checkParallel $$(discover)
