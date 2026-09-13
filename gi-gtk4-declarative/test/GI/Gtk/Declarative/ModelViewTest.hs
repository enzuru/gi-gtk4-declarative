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

import           Control.Concurrent             ( threadDelay )
import           Control.Concurrent.STM
import           Control.Monad.IO.Class         ( MonadIO
                                                , liftIO
                                                )
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
  = Clicked
  | Toggled Word
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

-- | Rows with an event controller on each, which is what a row that
-- answers a click looks like.
clickableRows :: Vector Text -> Widget Event
clickableRows items = listView
  []
  (defaultListViewParams
      (\text ->
        widget Gtk.Label [#label := text, onClickPressed (\_n _x _y -> Clicked)]
      )
    )
    { rows = items
    }

-- | Rows with a button each, which are compared, so that a patch
-- leaves them where they are.
comparedButtonRows :: Vector (Word, Text) -> Widget Event
comparedButtonRows items = listView
  []
  (defaultListViewParams
      (\(row, text) ->
        widget Gtk.ToggleButton [#label := text, on #toggled (Toggled row)]
      )
    )
    { rows         = items
    , rowUnchanged = Just (==)
    }

-- | Rows that cannot be selected and can be activated, which is what a
-- view whose rows are not a choice but can still be opened looks like.
unselectableActivatableRows :: Vector Text -> Widget Event
unselectableActivatableRows items = listView
  []
  (defaultListViewParams (\text -> widget Gtk.Label [#label := text]))
    { rows          = items
    , onActivated   = Just Activated
    , selectionMode = SelectNothing
    }

-- | Rows whose label is the item and something else, so that a row
-- which is drawn again can be told from one that is left alone.
--
-- The comparison says a row need not be drawn again when its item is
-- the same value, which is a promise about the renderer: that it reads
-- its item and nothing else. These rows break that promise on purpose.
suffixedRows :: Maybe (Text -> Text -> Bool) -> Vector Text -> Text -> Widget Event
suffixedRows compare' items suffix = listView
  []
  (defaultListViewParams
      (\text -> widget Gtk.Label [#label := (text <> suffix)])
    )
    { rows         = items
    , rowUnchanged = compare'
    }

-- | Rows that cannot be selected, which is what a view whose rows are
-- not a choice asks for.
unselectableRows :: Vector Text -> Widget Event
unselectableRows items = listView
  []
  (defaultListViewParams (\text -> widget Gtk.Label [#label := text]))
    { rows          = items
    , onSelected    = Just Selected
    , selectionMode = SelectNothing
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

-- | A row whose item changed is drawn again, comparison or no
-- comparison.
prop_a_compared_row_is_drawn_again_when_its_item_changes =
  withTests 1 . property $ do
    labels <- evalIO $ renderViews
      [ suffixedRows (Just (==)) ["one", "two"] ""
      , suffixedRows (Just (==)) ["one", "CHANGED"] ""
      ]
      rowLabels
    labels === ["one", "CHANGED"]

-- | A row whose item did not change is left alone: not rendered, not
-- patched, and not subscribed to again.
--
-- Here the renderer reads something other than its item, so leaving
-- the row alone is something a person can see. That is the promise the
-- comparison asks for, and this is what breaking it looks like.
prop_a_compared_row_that_did_not_change_is_left_alone =
  withTests 1 . property $ do
    (compared, redrawn) <- evalIO $ do
      compared' <- renderViews
        [ suffixedRows (Just (==)) ["one", "two"] ""
        , suffixedRows (Just (==)) ["one", "two"] "!"
        ]
        rowLabels
      redrawn' <- renderViews
        [ suffixedRows Nothing ["one", "two"] ""
        , suffixedRows Nothing ["one", "two"] "!"
        ]
        rowLabels
      pure (compared', redrawn')
    compared === ["one", "two"]
    redrawn === ["one!", "two!"]

-- | A row's widget is used again for another row as the view scrolls,
-- and a controller lives on the widget rather than on the
-- subscription, so a row that is drawn again must not leave another
-- controller behind.
prop_a_row_keeps_one_controller_however_often_it_is_drawn =
  withTests 1 . property $ do
    (baseline, counts) <- evalIO $ do
      baseline' <- runUI
        (countControllers =<< Gtk.toWidget =<< Gtk.new Gtk.Label [])
      counts' <- renderViews
        [ clickableRows ["one", "two"]
        , clickableRows ["ONE", "two"]
        , clickableRows ["one", "TWO"]
        , clickableRows ["one", "two"]
        ]
        rowControllerCounts
      pure (baseline', counts')
    counts === replicate (length counts) (baseline + 1)

-- | A row that a patch left alone still emits. Its subscription is the
-- one from before, which is the point: the markup is the same markup,
-- so its handlers are the same handlers.
prop_a_row_that_was_left_alone_still_emits = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let markup = comparedButtonRows [(0, "first"), (1, "second")]
    (window, state, view, sub) <- runUI $ do
      state'   <- create markup
      view'    <- someStateWidget state'
      window'  <- Gtk.new Gtk.Window
                          [#defaultWidth Gtk.:= 400, #defaultHeight Gtk.:= 300]
      scroller <- Gtk.new Gtk.ScrolledWindow []
      Gtk.scrolledWindowSetChild scroller (Just view')
      Gtk.windowSetChild window' (Just scroller)
      Gtk.windowPresent window'
      sub' <- subscribe markup state' (atomically . writeTBQueue received)
      pure (window', state', view', sub')
    settle
    -- Two patches that change nothing, which the comparison answers
    -- for: the rows are not drawn again, and not subscribed to again.
    _ <- runUI (patch' state markup markup)
    settle
    _ <- runUI (patch' state markup markup)
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

-- | Nothing is selected under 'SelectNothing', but a row can still be
-- activated, which is what a double click and Enter go through.
prop_a_view_that_selects_nothing_still_activates = withTests 1 . property $ do
  (found, events) <- evalIO $ do
    received <- newTBQueueIO 10
    let markup = unselectableActivatableRows ["one", "two", "three"]
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

-- * Scrolling, and the widgets that come back from it

-- | Rows of two kinds, told apart by what the item says. A row whose
-- widget is used again for an item of the other kind has to be built
-- again, which is the path a patch cannot reach: only scrolling binds
-- a widget to an item it was not made for.
mixedKindRows :: Vector Text -> Maybe Word -> Widget Event
mixedKindRows items scroll = listView
  []
  (defaultListViewParams render) { rows = items, scrollTo = scroll }
 where
  render text
    | "button" `Text.isPrefixOf` text
    = widget Gtk.ToggleButton [#label := text]
    | otherwise
    = widget Gtk.Label [#label := text]

-- | Two hundred rows, half of them buttons.
manyRows :: Vector Text
manyRows = Vector.fromList
  [ (if even index then "label-" else "button-") <> Text.pack (show index)
  | index <- [0 .. 199 :: Int]
  ]

-- | Render a view in a scrolled window, patch it with the rest, and
-- hand the view and the scroller to the action.
renderScrolling
  :: [Widget Event] -> (Gtk.Widget -> Gtk.ScrolledWindow -> IO a) -> IO a
renderScrolling [] _ = fail "renderScrolling: no markup to render"
renderScrolling (first : rest) f = do
  (window, state, view, scroller) <- runUI $ do
    state'   <- create first
    view'    <- someStateWidget state'
    window'  <- Gtk.new Gtk.Window
                        [#defaultWidth Gtk.:= 400, #defaultHeight Gtk.:= 300]
    scroller <- Gtk.new Gtk.ScrolledWindow []
    Gtk.scrolledWindowSetChild scroller (Just view')
    Gtk.windowSetChild window' (Just scroller)
    Gtk.windowPresent window'
    pure (window', state', view', scroller)
  settle
  _      <- foldM step (state, first) rest
  result <- runUI (f view scroller)
  runUI (Gtk.windowDestroy window)
  pure result
 where
  step (state, old) new = do
    state' <- runUI (patch' state old new)
    settle
    pure (state', new)

-- | A view scrolls where the markup says. Scrolling is a command: it
-- happens when the value differs from the one before, so a view
-- function that keeps saying the same thing leaves the user where they
-- scrolled to.
prop_a_view_scrolls_where_it_is_told = withTests 1 . property $ do
  (atRest, scrolled, again, back) <- evalIO $ do
    let markup = mixedKindRows manyRows
    (window, state, scroller) <- runUI $ do
      state'    <- create (markup Nothing)
      view      <- someStateWidget state'
      window'   <- Gtk.new Gtk.Window
                           [#defaultWidth Gtk.:= 400, #defaultHeight Gtk.:= 300]
      scroller' <- Gtk.new Gtk.ScrolledWindow []
      Gtk.scrolledWindowSetChild scroller' (Just view)
      Gtk.windowSetChild window' (Just scroller')
      Gtk.windowPresent window'
      pure (window', state', scroller')
    frames
    atRest'   <- runUI (valueOf scroller)
    _         <- runUI (patch' state (markup Nothing) (markup (Just 150)))
    frames
    scrolled' <- runUI (valueOf scroller)
    -- The same command again, which is not a new command.
    _         <- runUI (patch' state (markup (Just 150)) (markup (Just 150)))
    frames
    again'    <- runUI (valueOf scroller)
    _         <- runUI (patch' state (markup (Just 150)) (markup (Just 0)))
    frames
    back'     <- runUI (valueOf scroller)
    runUI (Gtk.windowDestroy window)
    pure (atRest', scrolled', again', back')
  atRest === 0
  (scrolled > 0) === True
  again === scrolled
  back === 0

-- | A row widget that is used again for an item of the other kind is
-- built again. Only scrolling can ask for that: a patch draws a row
-- against the markup it was drawn from, and a bind draws it against
-- whatever item it lands on.
prop_a_recycled_row_shows_the_kind_its_item_asks_for =
  withTests 1 . property $ do
    kinds <- evalIO $ do
      let markup = mixedKindRows manyRows
      (window, state, view) <- runUI $ do
        state'    <- create (markup Nothing)
        view'     <- someStateWidget state'
        window'   <- Gtk.new Gtk.Window
                             [#defaultWidth Gtk.:= 400, #defaultHeight Gtk.:= 300]
        scroller' <- Gtk.new Gtk.ScrolledWindow []
        Gtk.scrolledWindowSetChild scroller' (Just view')
        Gtk.windowSetChild window' (Just scroller')
        Gtk.windowPresent window'
        pure (window', state', view')
      settle
      -- Scroll far enough that every widget on screen has been used
      -- for another row, and by an odd number of rows so that the
      -- kinds do not line up as they were.
      _     <- runUI (patch' state (markup Nothing) (markup (Just 101)))
      settle
      _     <- runUI (patch' state (markup (Just 101)) (markup (Just 42)))
      settle
      kinds' <- runUI (rowKinds view)
      runUI (Gtk.windowDestroy window)
      pure kinds'
    -- Every row on screen is the kind its own item asks for.
    filter wrongKind kinds === []
 where
  wrongKind (text, isButton) = Text.isPrefixOf "button" text /= isButton

-- | What each row on screen says, and whether it is a button.
rowKinds :: Gtk.Widget -> IO [(Text, Bool)]
rowKinds view = do
  widgets <- descendants view
  found   <- traverse describe widgets
  pure (mapMaybe id found)
 where
  describe w = do
    asButton <- Gtk.castTo Gtk.ToggleButton w
    case asButton of
      Just b  -> fmap (\text -> (maybe "" id text, True)) <$> (Just <$> Gtk.buttonGetLabel b)
      Nothing -> do
        asLabel <- Gtk.castTo Gtk.Label w
        case asLabel of
          -- The label inside a button is not a row of its own.
          Just l  -> do
            parent <- Gtk.widgetGetParent l
            inButton <- maybe (pure Nothing) (Gtk.castTo Gtk.ToggleButton) parent
            case inButton of
              Just _  -> pure Nothing
              Nothing -> Just . (\text -> (text, False)) <$> Gtk.get l #label
          Nothing -> pure Nothing

-- | Let the main loop draw a frame or two, which is when a list view
-- carries out a scroll it was asked for.
frames :: MonadIO m => m ()
frames = do
  settle
  liftIO (threadDelay 300000)
  settle

-- | Where a scrolled window is scrolled to.
valueOf :: Gtk.ScrolledWindow -> IO Double
valueOf scroller = do
  adjustment <- Gtk.scrolledWindowGetVadjustment scroller
  Gtk.adjustmentGetValue adjustment

-- | How many controllers each row on screen carries.
rowControllerCounts :: Gtk.Widget -> IO [Word32]
rowControllerCounts view = do
  widgets <- descendants view
  labels  <- traverse (Gtk.castTo Gtk.Label) widgets
  traverse countControllers =<< traverse Gtk.toWidget (mapMaybe id labels)

countControllers :: Gtk.Widget -> IO Word32
countControllers widget' =
  Gtk.widgetObserveControllers widget' >>= Gio.listModelGetNItems

-- | Selecting a row is what a click on it does, and the action GTK
-- puts on the view for exactly that is how a test does it.
--
-- Under 'SelectNothing' the model refuses, so nothing is selected and
-- nothing is emitted. A spreadsheet wants this: what is selected there
-- is a cell, which the program draws itself.
prop_a_view_that_selects_nothing_selects_nothing = withTests 1 . property $ do
  (selectedRow, events) <- evalIO (selectThroughAction (unselectableRows rows'))
  selectedRow === False
  events === []

-- | The same view, with the selection left as it comes, selects.
prop_a_view_that_selects_one_selects_it = withTests 1 . property $ do
  (selectedRow, events) <- evalIO
    (selectThroughAction (selectableRows rows' Nothing))
  selectedRow === True
  events === [Selected 1]

rows' :: Vector Text
rows' = ["one", "two", "three"]

-- | Ask the view to select its second row, and read back whether the
-- model says it is selected, and what the view emitted.
selectThroughAction :: Widget Event -> IO (Bool, [Event])
selectThroughAction markup = do
  received            <- newTBQueueIO 10
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
  chosen <- runUI $ do
    -- The action takes the position, whether to modify the selection,
    -- and whether to extend it.
    arguments <- toGVariant (1 :: Word32, False, False)
    _         <- Gtk.widgetActivateAction view "list.select-item" (Just arguments)
    listView' <- Gtk.unsafeCastTo Gtk.ListView view
    model     <- Gtk.listViewGetModel listView'
    maybe (pure False) (`Gtk.selectionModelIsSelected` 1) model
  settle
  runUI (cancel sub >> Gtk.windowDestroy window)
  events <- atomically (flushTBQueue received)
  pure (chosen, events)

-- | The selection model is one GTK object or the other, so a view
-- whose mode changes is built again rather than patched.
prop_changing_the_selection_mode_builds_the_view_again =
  withTests 1 . property $ do
    same <- evalIO $ do
      let first  = selectableRows rows' Nothing
          second = unselectableRows rows'
      (window, state, view) <- runUI $ do
        state'  <- create first
        view'   <- someStateWidget state'
        window' <- Gtk.new Gtk.Window []
        Gtk.windowSetChild window' (Just view')
        pure (window', state', view')
      after <- runUI $ do
        patched <- patch' state first second
        someStateWidget patched
      runUI (Gtk.windowDestroy window)
      pure (after == view)
    same === False

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
