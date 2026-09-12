{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for the model-based views.
--
-- A list view builds a widget only for the rows on screen, so these
-- tests put it in a window and present it. Nothing is bound before
-- that: an unpresented view has no size, and a view with no size has no
-- rows.
module GI.Gtk.Declarative.ModelViewTest where

import           Control.Concurrent.STM
import           Control.Monad                  ( foldM )
import           Data.Maybe                     ( mapMaybe )
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.ModelView.ListView
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.TestUtils

data Event = Toggled Word | Selected Word | Activated Word
  deriving (Eq, Show)

-- * Markup

labelRows :: Vector Text -> Widget Event
labelRows items = listView
  []
  (defaultListViewParams (\text -> widget Gtk.Label [#label := text]))
    { rows = items
    }

buttonRows :: Vector (Word, Text) -> Widget Event
buttonRows items = listView
  []
  (defaultListViewParams
      (\(row, text) ->
        widget Gtk.ToggleButton [#label := text, on #toggled (Toggled row)]
      )
    )
    { rows = items
    }

selectableRows :: Vector Text -> Maybe Word -> Widget Event
selectableRows items chosen = listView
  []
  (defaultListViewParams (\text -> widget Gtk.Label [#label := text]))
    { rows       = items
    , selected   = chosen
    , onSelected = Just Selected
    }

-- * Rendering and patching

-- | Render the first markup in a presented window, patch it with each
-- of the others, and hand the view to the action. The window is shown,
-- because rows are built for what is on screen and nothing else.
renderViews :: [Widget Event] -> (Gtk.Widget -> IO a) -> IO a
renderViews []             _ = fail "renderViews: no markup to render"
renderViews (first : rest) f = do
  (window, state, view) <- runUI $ do
    state'   <- create first
    view'    <- someStateWidget state'
    window'  <- Gtk.new Gtk.Window
                        [#defaultWidth Gtk.:= 400, #defaultHeight Gtk.:= 300]
    scroller <- Gtk.new Gtk.ScrolledWindow []
    Gtk.scrolledWindowSetChild scroller (Just view')
    Gtk.windowSetChild window' (Just scroller)
    Gtk.windowPresent window'
    pure (window', state', view')
  settle
  _      <- foldM step (state, first) rest
  result <- runUI (f view)
  runUI (Gtk.windowDestroy window)
  pure result
 where
  step (state, old) new = do
    state' <- runUI (patch' state old new)
    settle
    pure (state', new)

-- | What the rows on screen say.
rowLabels :: Gtk.Widget -> IO [Text]
rowLabels view = do
  widgets <- descendants view
  labels  <- traverse asLabel widgets
  pure (mapMaybe id labels)
 where
  asLabel w = do
    label <- Gtk.castTo Gtk.Label w
    traverse (`Gtk.get` #label) label

-- * The tests

prop_rows_are_rendered = withTests 1 . property $ do
  labels <- evalIO $ renderViews [labelRows ["one", "two", "three"]] rowLabels
  labels === ["one", "two", "three"]

-- | A row shows what its item says, even when the number of rows has
-- not changed. The model is the same, so GTK has no reason to bind
-- anything, and the view has to say so itself.
prop_a_changed_item_reaches_its_row = withTests 1 . property $ do
  labels <- evalIO $ renderViews
    [labelRows ["one", "two"], labelRows ["one", "CHANGED"]]
    rowLabels
  labels === ["one", "CHANGED"]

prop_rows_are_added_and_taken_away = withTests 1 . property $ do
  (grown, shrunk) <- evalIO $ do
    grown'  <- renderViews [labelRows ["one"], labelRows ["one", "two", "three"]]
                           rowLabels
    shrunk' <- renderViews [labelRows ["one", "two", "three"], labelRows ["one"]]
                           rowLabels
    pure (grown', shrunk')
  grown === ["one", "two", "three"]
  shrunk === ["one"]

-- | A widget inside a row emits through the view, which is what says
-- the rows are subscribed to.
prop_a_row_emits_its_events = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let markup = buttonRows [(0, "first"), (1, "second")]
    (window, view, sub) <- runUI $ do
      state    <- create markup
      view'    <- someStateWidget state
      window'  <- Gtk.new Gtk.Window
                          [#defaultWidth Gtk.:= 400, #defaultHeight Gtk.:= 300]
      scroller <- Gtk.new Gtk.ScrolledWindow []
      Gtk.scrolledWindowSetChild scroller (Just view')
      Gtk.windowSetChild window' (Just scroller)
      Gtk.windowPresent window'
      sub' <- subscribe markup state (atomically . writeTBQueue received)
      pure (window', view', sub')
    settle
    runUI $ do
      buttons <- rowButtons view
      case buttons of
        (button : _) -> Gtk.toggleButtonSetActive button True
        []           -> fail "no rows on screen"
      cancel sub
      Gtk.windowDestroy window
    atomically (flushTBQueue received)
  events === [Toggled 0]

-- | Selecting a row emits, whoever did the selecting. Here the markup
-- asks for a row to be selected, which is a command rather than a
-- property: it is carried out when it changes.
prop_selecting_a_row_emits = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let first  = selectableRows ["one", "two", "three"] Nothing
        second = selectableRows ["one", "two", "three"] (Just 2)
    (window, state, sub) <- runUI $ do
      state'   <- create first
      view'    <- someStateWidget state'
      window'  <- Gtk.new Gtk.Window
                          [#defaultWidth Gtk.:= 400, #defaultHeight Gtk.:= 300]
      scroller <- Gtk.new Gtk.ScrolledWindow []
      Gtk.scrolledWindowSetChild scroller (Just view')
      Gtk.windowSetChild window' (Just scroller)
      Gtk.windowPresent window'
      sub' <- subscribe first state' (atomically . writeTBQueue received)
      pure (window', state', sub')
    settle
    _ <- runUI (patch' state first second)
    settle
    runUI $ do
      cancel sub
      Gtk.windowDestroy window
    atomically (flushTBQueue received)
  events === [Selected 2]

-- | The buttons in the rows on screen.
rowButtons :: Gtk.Widget -> IO [Gtk.ToggleButton]
rowButtons view = do
  widgets <- descendants view
  buttons <- traverse (Gtk.castTo Gtk.ToggleButton) widgets
  pure (mapMaybe id buttons)

-- * Test collection

tests :: IO Bool
tests = checkParallel $$(discover)
