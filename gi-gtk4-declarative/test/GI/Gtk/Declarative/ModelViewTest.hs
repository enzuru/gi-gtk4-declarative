{-# LANGUAGE DisambiguateRecordFields #-}
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
import           Data.Int                       ( Int32 )
import           Data.Maybe                     ( mapMaybe )
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import           Data.GI.Base.GVariant          ( toGVariant )
import           Data.Word                      ( Word32 )
import qualified GI.Gio                        as Gio
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.ModelView.ColumnView
                                                ( Column(..)
                                                , ColumnViewParams(..)
                                                , column
                                                , columnView
                                                , defaultColumnViewParams
                                                )
import qualified GI.Gtk.Declarative.ModelView.ColumnView
                                               as ColumnView
import           GI.Gtk.Declarative.ModelView.ListView
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.TestUtils

data Event
  = Toggled Word
  | Selected Word
  | Activated Word
  | Resized Int32
  | HeaderMenu Text
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

activatableRows :: Vector Text -> Widget Event
activatableRows items = listView
  []
  (defaultListViewParams (\text -> widget Gtk.Label [#label := text]))
    { rows        = items
    , onActivated = Just Activated
    }

-- | Rows whose widget is a label or a button, depending on the item,
-- so that changing an item replaces the row's widget rather than
-- patching it.
mixedRows :: Vector Bool -> Widget Event
mixedRows items = listView
  []
  (defaultListViewParams
      (\isLabel -> if isLabel
        then widget Gtk.Label [#label := ("a label" :: Text)]
        else widget Gtk.ToggleButton [#label := ("a button" :: Text)]
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

-- | A row whose widget has to be replaced gets the new one. The number
-- of rows is the same, so GTK never binds the row again, and the view
-- has to put the new widget in the cell itself.
prop_a_replaced_row_widget_is_put_in_its_cell = withTests 1 . property $ do
  (labels, buttons) <- evalIO $ renderViews
    [mixedRows [True], mixedRows [False]]
    (\view -> do
      labels'  <- rowLabels view
      buttons' <- rowButtons view
      pure (labels', length buttons')
    )
  labels === ["a button"]
  buttons === 1

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

-- * Column views

-- | Two columns over a pair of texts, named by the keys given.
pairColumns :: [(Text, Text)] -> Vector (Column (Text, Text) Event)
pairColumns = Vector.fromList . map each
 where
  each (key, title)
    | key == "left" = column key title (\(l, _) -> label l)
    | otherwise     = column key title (\(_, r) -> label r)
  label text = widget Gtk.Label [#label := text]

pairRows :: Vector (Text, Text) -> [(Text, Text)] -> Widget Event
pairRows items theColumns =
  columnView [] (defaultColumnViewParams (pairColumns theColumns)) { ColumnView.rows = items }

prop_cells_are_rendered = withTests 1 . property $ do
  labels <- evalIO $ renderViews
    [pairRows [("a", "1"), ("b", "2")] [("left", "Left"), ("right", "Right")]]
    rowLabels
  -- Every label below the view, which is the two column titles in the
  -- header and then the cells, a row at a time.
  Text.intercalate "," labels === "Left,Right,a,1,b,2"

prop_columns_are_added_and_taken_away = withTests 1 . property $ do
  (grown, shrunk) <- evalIO $ do
    grown' <- renderViews
      [ pairRows [("a", "1")] [("left", "Left")]
      , pairRows [("a", "1")] [("left", "Left"), ("right", "Right")]
      ]
      columnTitles
    shrunk' <- renderViews
      [ pairRows [("a", "1")] [("left", "Left"), ("right", "Right")]
      , pairRows [("a", "1")] [("right", "Right")]
      ]
      columnTitles
    pure (grown', shrunk')
  grown === ["Left", "Right"]
  shrunk === ["Right"]

prop_columns_keep_their_order = withTests 1 . property $ do
  titles <- evalIO $ renderViews
    [ pairRows [("a", "1")] [("left", "Left"), ("right", "Right")]
    , pairRows [("a", "1")] [("right", "Right"), ("left", "Left")]
    ]
    columnTitles
  titles === ["Right", "Left"]

-- | A column that keeps its key keeps its widget, which is what makes
-- adding a column cost one column rather than all of them.
prop_a_column_that_stays_keeps_its_widget = withTests 1 . property $ do
  same <- evalIO $ do
    let first  = pairRows [("a", "1")] [("left", "Left")]
        second = pairRows [("a", "1")] [("left", "Left"), ("right", "Right")]
    (window, state, view) <- runUI $ do
      state'  <- create first
      view'   <- someStateWidget state'
      window' <- Gtk.new Gtk.Window
                         [#defaultWidth Gtk.:= 400, #defaultHeight Gtk.:= 300]
      Gtk.windowSetChild window' (Just view')
      Gtk.windowPresent window'
      pure (window', state', view')
    settle
    before <- runUI (columnWidgets view)
    _      <- runUI (patch' state first second)
    settle
    after <- runUI (columnWidgets view)
    runUI (Gtk.windowDestroy window)
    pure (take 1 before == take 1 after && length after == 2)
  same === True

prop_a_column_resize_emits = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let widths :: Int32 -> Widget Event
        widths width = columnView
          []
          (defaultColumnViewParams
              [ (column "left" "Left" (\(l, _) -> widget Gtk.Label [#label := l]))
                  { columnFixedWidth = Just width
                  , onResized        = Just Resized
                  }
              ]
            )
            { ColumnView.rows = [("a" :: Text, "1" :: Text)] }
        first  = widths 120
        second = widths 200
    (window, state, sub) <- runUI $ do
      state'  <- create first
      view'   <- someStateWidget state'
      window' <- Gtk.new Gtk.Window
                         [#defaultWidth Gtk.:= 400, #defaultHeight Gtk.:= 300]
      Gtk.windowSetChild window' (Just view')
      Gtk.windowPresent window'
      sub' <- subscribe first state' (atomically . writeTBQueue received)
      pure (window', state', sub')
    settle
    _ <- runUI (patch' state first second)
    settle
    runUI (cancel sub >> Gtk.windowDestroy window)
    atomically (flushTBQueue received)
  events === [Resized 200]

-- | A column can carry a menu on its header, and the items of that
-- menu emit like any other event in the library.
prop_a_column_header_menu_emits = withTests 1 . property $ do
  (found, events) <- evalIO (headerMenuEvents [withHeaderMenu "insert"])
  found === True
  events === [HeaderMenu "insert"]

-- | The menu keeps its shape across the patch, so the model is not
-- built again. The events behind it are still this render's.
prop_a_patched_header_menu_emits_the_new_event = withTests 1 . property $ do
  (found, events) <- evalIO
    (headerMenuEvents [withHeaderMenu "insert", withHeaderMenu "remove"])
  found === True
  events === [HeaderMenu "remove"]

-- | A column with a one-item header menu, emitting this event.
withHeaderMenu :: Text -> Widget Event
withHeaderMenu what = columnView
  []
  (defaultColumnViewParams
      [ (column "name" "Name" (\(l, _) -> widget Gtk.Label [#label := l]))
          { columnHeaderMenu = [menuItem "Do it" (HeaderMenu what)]
          }
      ]
    )
    { ColumnView.rows = [("a" :: Text, "1" :: Text)]
    }

-- | Render the markups in turn, then activate the action behind the
-- first item of the first column's header menu.
headerMenuEvents :: [Widget Event] -> IO (Bool, [Event])
headerMenuEvents []             = fail "headerMenuEvents: no markup"
headerMenuEvents (first : rest) = do
  received            <- newTBQueueIO 10
  (window, state, view, sub) <- runUI $ do
    state'  <- create first
    view'   <- someStateWidget state'
    window' <- Gtk.new Gtk.Window
                       [#defaultWidth Gtk.:= 400, #defaultHeight Gtk.:= 300]
    Gtk.windowSetChild window' (Just view')
    Gtk.windowPresent window'
    sub' <- subscribe first state' (atomically . writeTBQueue received)
    pure (window', state', view', sub')
  settle
  _     <- foldM (\(s, old) new -> do
                   s' <- runUI (patch' s old new)
                   settle
                   pure (s', new))
                 (state, first)
                 rest
  found <- runUI
    (Gtk.widgetActivateAction view "column-menu-name.item0" Nothing)
  settle
  runUI (cancel sub >> Gtk.windowDestroy window)
  events <- atomically (flushTBQueue received)
  pure (found, events)

-- | The titles of the view's columns, in order.
columnTitles :: Gtk.Widget -> IO [Text]
columnTitles view = do
  columns' <- columnWidgets view
  traverse (fmap (maybe "" id) . Gtk.columnViewColumnGetTitle) columns'

columnWidgets :: Gtk.Widget -> IO [Gtk.ColumnViewColumn]
columnWidgets view = do
  asColumnView <- Gtk.castTo Gtk.ColumnView view
  case asColumnView of
    Nothing -> pure []
    Just cv -> do
      model <- Gtk.columnViewGetColumns cv
      count <- Gio.listModelGetNItems model
      items <- traverse (Gio.listModelGetItem model) [0 .. count - 1]
      traverse (Gtk.unsafeCastTo Gtk.ColumnViewColumn) (mapMaybe id items)

-- | Activating a row, which a person does with a double click or with
-- Enter, and a test does through the action GTK puts on the view for
-- exactly that.
prop_activating_a_row_emits = withTests 1 . property $ do
  (found, events) <- evalIO $ do
    received <- newTBQueueIO 10
    let markup = activatableRows ["one", "two", "three"]
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
    found' <- runUI $ do
      position <- toGVariant (1 :: Word32)
      Gtk.widgetActivateAction view "list.activate-item" (Just position)
    settle
    runUI (cancel sub >> Gtk.windowDestroy window)
    events' <- atomically (flushTBQueue received)
    pure (found', events')
  found === True
  events === [Activated 1]

-- | The buttons in the rows on screen.
rowButtons :: Gtk.Widget -> IO [Gtk.ToggleButton]
rowButtons view = do
  widgets <- descendants view
  buttons <- traverse (Gtk.castTo Gtk.ToggleButton) widgets
  pure (mapMaybe id buttons)

-- * Test collection

tests :: IO Bool
tests = checkParallel $$(discover)
