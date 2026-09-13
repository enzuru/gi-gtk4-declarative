-- The constraints below name a specific gi-gtk class and IsWidget both,
-- which GHC would rather saw spelled out as descendant constraints.
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The shared machinery behind the model-based views.
--
-- A GTK 4 list widget holds no children. It holds a list model and a
-- factory, creates a widget when a row scrolls into sight, binds it to
-- a position, unbinds it when the row leaves, and binds that same
-- widget to another position later. There is no fixed list of children
-- to diff, so this is a second patching path rather than another
-- container.
--
-- What this module keeps is one record per realized row: the markup the
-- row shows, its state, and its subscription. A bind patches that
-- record rather than building the row again, which is what makes
-- recycling worth having.
module GI.Gtk.Declarative.ModelView.Internal
  ( ViewState(..)
  , SelectionMode(..)
  , Selection(..)
  , selectionModeOf
  , selectionModel
  , Row(..)
  , theColumn
  , Cell(..)
  , Commands(..)
  , newViewState
  , listItemCell
  , columnViewCell
  , bindCell
  , unbindCell
  , teardownCell
  , rebindRows
  , setItems
  , standIns
  , objectKey
  , noSink
  )
where

import           Control.Monad                  ( when )
import           Data.Foldable                  ( for_ )
import           Data.GI.Base                   ( withManagedPtr )
import           Data.HashMap.Strict            ( HashMap )
import qualified Data.HashMap.Strict           as HashMap
import           Data.IORef
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import qualified Data.Text.Read                as Text
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import           Foreign.Ptr                    ( castPtr
                                                , ptrToWordPtr
                                                )
import qualified GI.GObject                    as GObject
import qualified GI.Gio                        as Gio
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.Widget

-- | One realized row.
data Row item event = Row
  { rowMarkup :: Widget event
  -- ^ What this row currently shows.
  , rowItem   :: item
  -- ^ The item it was drawn from, which is what says whether it has to
  -- be drawn again.
  , rowState  :: SomeState
  -- ^ The state of the widget showing it.
  , rowIndex  :: Int
  -- ^ Which item of the vector it shows.
  , rowColumn :: Text
  -- ^ Which column renders it. A list view has the one column, whose
  -- key is the empty text.
  , rowCell   :: Cell
  -- ^ The cell it sits in, so that a row whose widget has to be
  -- replaced can be given the new one. The cell is two closures over a
  -- list item GTK owns, and this record is dropped on teardown, so
  -- holding it for as long as the record lives is safe.
  , rowCancel :: IO ()
  -- ^ Cancels the row's subscription. Emptied on unbind.
  }

-- | Whether a view lets a row be selected.
--
-- A list of things to choose from wants 'SelectOne'. A view whose rows
-- are not a choice, such as a spreadsheet where what is selected is a
-- cell rather than a row, wants 'SelectNothing': GTK then highlights
-- nothing, rather than the program undoing a highlight in its
-- stylesheet.
data SelectionMode
  = SelectNothing
  -- ^ Nothing is ever selected. 'GI.Gtk.Declarative.ModelView.ListView.selected',
  -- 'GI.Gtk.Declarative.ModelView.ListView.onSelected', and the
  -- selection command all do nothing. Activating a row still works,
  -- which is what a double click and Enter go through.
  | SelectOne
  -- ^ One row at a time, which is what a list view does by default.
  deriving (Eq, Show)

-- | The selection model a view holds, which is one GTK object or the
-- other depending on the mode.
data Selection
  = SelectionOne Gtk.SingleSelection
  | SelectionNone Gtk.NoSelection

selectionModeOf :: Selection -> SelectionMode
selectionModeOf = \case
  SelectionOne  _ -> SelectOne
  SelectionNone _ -> SelectNothing

-- | The selection as the interface a list widget takes.
selectionModel :: Selection -> IO Gtk.SelectionModel
selectionModel = \case
  SelectionOne  selection -> Gtk.toSelectionModel selection
  SelectionNone selection -> Gtk.toSelectionModel selection

-- | The commands a view takes: things that happen rather than things
-- that are. They are carried out when the value given differs from the
-- value given last time, so that a view function which repeats itself
-- does nothing.
data Commands = Commands
  { commandSelected :: Maybe Word
  , commandScrollTo :: Maybe Word
  }
  deriving (Eq, Show)

-- | What a view keeps between patches.
--
-- The event type is in here, which is why the widgets built on this ask
-- for a `Typeable` event. Everything the factory callbacks need is
-- behind an `IORef`, because those callbacks outlive any one render.
data ViewState item event = ViewState
  { viewModel      :: Gtk.StringList
  -- ^ One stand-in object per row, holding the row's index as text.
  -- The rows themselves stay in Haskell.
  , viewSelection  :: Selection
  , viewItems      :: IORef (Vector item)
  , viewRenderers  :: IORef (HashMap Text (item -> Widget event))
  -- ^ How to render a cell, by column key. A list view keeps its one
  -- renderer under the empty key.
  , viewSink       :: IORef (event -> IO ())
  -- ^ Where a row's events go. A no-op until the view is subscribed to.
  , viewRows       :: IORef (HashMap Word (Row item event))
  , viewUnchanged  :: IORef (Maybe (item -> item -> Bool))
  -- ^ Whether a row on screen can be left alone, given the item it was
  -- drawn from and the item it would be drawn from now. Nothing draws
  -- every row again on every patch.
  , viewCommands   :: IORef Commands
  , viewOnSelected :: IORef (Maybe (Word -> event))
  , viewOnActivated :: IORef (Maybe (Word -> event))
  }

-- | What the machinery needs from a list item or a column view cell.
-- GTK hands a list view one and a column view the other, and they are
-- different types with the same three operations.
data Cell = Cell
  { cellStandIn  :: IO (Maybe GObject.Object)
  , cellSetChild :: Maybe Gtk.Widget -> IO ()
  }

listItemCell :: Gtk.ListItem -> Cell
listItemCell item = Cell { cellStandIn  = Gtk.listItemGetItem item
                         , cellSetChild = Gtk.listItemSetChild item
                         }

columnViewCell :: Gtk.ColumnViewCell -> Cell
columnViewCell cell = Cell { cellStandIn  = Gtk.columnViewCellGetItem cell
                           , cellSetChild = Gtk.columnViewCellSetChild cell
                           }

-- | Events go nowhere until the view is subscribed to.
noSink :: event -> IO ()
noSink _ = pure ()

-- | A stand-in string per row: the row's index, which is what a bind
-- reads to find its item. Binding by the stand-in rather than by the
-- position is what lets a sorting or filtering model sit in between.
standIns :: Int -> [Text]
standIns count = map (Text.pack . show) [0 .. count - 1]

-- | A key for a list item, which is the address it lives at. Stable for
-- as long as GTK keeps the item, which is what makes it a key.
objectKey :: Gtk.GObject o => o -> IO Word
objectKey object =
  withManagedPtr object (pure . fromIntegral . ptrToWordPtr . castPtr)

-- | The key a list view's single column goes under.
theColumn :: Text
theColumn = ""

newViewState
  :: SelectionMode
  -> Vector item
  -> HashMap Text (item -> Widget event)
  -> IO (ViewState item event)
newViewState mode items renderers = do
  model     <- Gtk.stringListNew (Just (standIns (Vector.length items)))
  -- Built and then handed the model, rather than built from it:
  -- gtk_single_selection_new takes the model over, and the value here
  -- would be left disowned.
  selection <- case mode of
    SelectOne -> do
      one <- Gtk.new Gtk.SingleSelection []
      Gtk.singleSelectionSetModel one (Just model)
      pure (SelectionOne one)
    SelectNothing -> do
      none <- Gtk.new Gtk.NoSelection []
      Gtk.noSelectionSetModel none (Just model)
      pure (SelectionNone none)
  ViewState model selection
    <$> newIORef items
    <*> newIORef renderers
    <*> newIORef noSink
    <*> newIORef HashMap.empty
    <*> newIORef Nothing
    <*> newIORef (Commands Nothing Nothing)
    <*> newIORef Nothing
    <*> newIORef Nothing

-- | Put new items in the view, resizing the model if the count changed.
--
-- The items are written before the model is spliced, because a splice
-- makes GTK bind rows again there and then, and those binds read what
-- is written here.
setItems :: ViewState item event -> Vector item -> IO ()
setItems state items = do
  writeIORef (viewItems state) items
  before <- Gio.listModelGetNItems (viewModel state)
  let after = fromIntegral (Vector.length items)
  when (before /= after)
    $ Gtk.stringListSplice (viewModel state)
                           0
                           before
                           (Just (standIns (Vector.length items)))

-- | Show a row. A row that has been shown before is patched rather than
-- built again, which is the whole point of a recycled widget.
bindCell :: ViewState item event -> Text -> Word -> Cell -> IO ()
bindCell state column key cell = do
  index     <- standInIndex cell
  items     <- readIORef (viewItems state)
  renderers <- readIORef (viewRenderers state)
  case (index >>= (items Vector.!?), HashMap.lookup column renderers) of
    (Just value, Just render) ->
      showRow state column key cell (maybe 0 id index) value (render value)
    _ -> pure ()

-- | The row this cell is bound to, read from its stand-in object.
standInIndex :: Cell -> IO (Maybe Int)
standInIndex cell = cellStandIn cell >>= \case
  Nothing     -> pure Nothing
  Just object -> do
    standIn <- Gtk.unsafeCastTo Gtk.StringObject object
    text    <- Gtk.stringObjectGetString standIn
    pure (either (const Nothing) (Just . fst) (Text.decimal text))

-- | Put markup in a cell, patching whatever was there before.
showRow
  :: ViewState item event
  -> Text
  -> Word
  -> Cell
  -> Int
  -> item
  -> Widget event
  -> IO ()
showRow state column key cell index value markup = do
  rows <- readIORef (viewRows state)
  row  <- case HashMap.lookup key rows of
    Just old -> do
      rowCancel old
      newState <- case patch (rowState old) (rowMarkup old) markup of
        Modify  modify    -> modify
        Keep              -> pure (rowState old)
        Replace createNew -> do
          created <- createNew
          cellSetChild cell . Just =<< someStateWidget created
          pure created
      pure (Row markup value newState index column cell (pure ()))
    Nothing -> do
      created <- create markup
      cellSetChild cell . Just =<< someStateWidget created
      pure (Row markup value created index column cell (pure ()))
  cancelRow <- subscribeRow state markup (rowState row)
  modifyIORef' (viewRows state) (HashMap.insert key row { rowCancel = cancelRow })

-- | A row publishes through the view's sink, which is a no-op until
-- somebody subscribes to the view and the real callback arrives.
subscribeRow :: ViewState item event -> Widget event -> SomeState -> IO (IO ())
subscribeRow state markup rowState' = do
  subscription <- subscribe markup
                            rowState'
                            (\event -> readIORef (viewSink state) >>= ($ event))
  pure (cancel subscription)

-- | The row left the screen. Its widget is kept for the next row to
-- use, and only its subscription goes.
unbindCell :: ViewState item event -> Word -> IO ()
unbindCell state key = do
  rows <- readIORef (viewRows state)
  for_ (HashMap.lookup key rows) $ \row -> do
    rowCancel row
    modifyIORef' (viewRows state)
                 (HashMap.insert key row { rowCancel = pure () })

-- | GTK is finished with this cell.
teardownCell :: ViewState item event -> Word -> IO ()
teardownCell state key = do
  rows <- readIORef (viewRows state)
  for_ (HashMap.lookup key rows) rowCancel
  modifyIORef' (viewRows state) (HashMap.delete key)

-- | Show the rows that are on screen again, against the items the view
-- holds now.
--
-- Without this, a patch that changes what an item says while leaving
-- the number of items alone would not reach the screen: the model has
-- not changed, so GTK has no reason to bind anything.
--
-- A view that says when a row has not changed is taken at its word,
-- and that row is left as it is: not rendered, not patched, and not
-- subscribed to again. Drawing a row costs more than everything else
-- in a patch of a view put together, and a view of six hundred cells
-- usually has two of them to change.
rebindRows :: ViewState item event -> IO ()
rebindRows state = do
  rows      <- readIORef (viewRows state)
  items     <- readIORef (viewItems state)
  renderers <- readIORef (viewRenderers state)
  unchanged <- readIORef (viewUnchanged state)
  for_ (HashMap.toList rows) $ \(key, row) ->
    for_ ((,) <$> items Vector.!? rowIndex row
              <*> HashMap.lookup (rowColumn row) renderers)
      $ \(value, render) ->
          case unchanged of
            Just same | same (rowItem row) value -> pure ()
            _                                    -> do
              let markup = render value
              rowCancel row
              newState <- case patch (rowState row) (rowMarkup row) markup of
                Modify  modify    -> modify
                Keep              -> pure (rowState row)
                Replace createNew -> do
                  created <- createNew
                  cellSetChild (rowCell row) . Just =<< someStateWidget created
                  pure created
              cancelRow <- subscribeRow state markup newState
              modifyIORef'
                (viewRows state)
                (HashMap.insert key row { rowMarkup = markup
                                        , rowItem   = value
                                        , rowState  = newState
                                        , rowCancel = cancelRow
                                        }
                )
