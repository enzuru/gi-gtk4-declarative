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
  , Row(..)
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
data Row event = Row
  { rowMarkup :: Widget event
  -- ^ What this row currently shows.
  , rowState  :: SomeState
  -- ^ The state of the widget showing it.
  , rowIndex  :: Int
  -- ^ Which item of the vector it shows.
  , rowCancel :: IO ()
  -- ^ Cancels the row's subscription. Emptied on unbind.
  }

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
  , viewSelection  :: Gtk.SingleSelection
  , viewItems      :: IORef (Vector item)
  , viewRender     :: IORef (item -> Widget event)
  , viewSink       :: IORef (event -> IO ())
  -- ^ Where a row's events go. A no-op until the view is subscribed to.
  , viewRows       :: IORef (HashMap Word (Row event))
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

newViewState
  :: Vector item
  -> (item -> Widget event)
  -> IO (ViewState item event)
newViewState items render = do
  model     <- Gtk.stringListNew (Just (standIns (Vector.length items)))
  -- Built and then handed the model, rather than built from it:
  -- gtk_single_selection_new takes the model over, and the value here
  -- would be left disowned.
  selection <- Gtk.new Gtk.SingleSelection []
  Gtk.singleSelectionSetModel selection (Just model)
  ViewState model selection
    <$> newIORef items
    <*> newIORef render
    <*> newIORef noSink
    <*> newIORef HashMap.empty
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
bindCell :: ViewState item event -> Word -> Cell -> IO ()
bindCell state key cell = do
  index <- standInIndex cell
  items <- readIORef (viewItems state)
  case index >>= (items Vector.!?) of
    Nothing    -> pure ()
    Just value -> do
      render <- readIORef (viewRender state)
      showRow state key cell (maybe 0 id index) (render value)

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
  :: ViewState item event -> Word -> Cell -> Int -> Widget event -> IO ()
showRow state key cell index markup = do
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
      pure (Row markup newState index (pure ()))
    Nothing -> do
      created <- create markup
      cellSetChild cell . Just =<< someStateWidget created
      pure (Row markup created index (pure ()))
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
rebindRows :: ViewState item event -> IO ()
rebindRows state = do
  rows   <- readIORef (viewRows state)
  items  <- readIORef (viewItems state)
  render <- readIORef (viewRender state)
  for_ (HashMap.toList rows) $ \(key, row) ->
    for_ (items Vector.!? rowIndex row) $ \value -> do
      let markup = render value
      rowCancel row
      newState <- case patch (rowState row) (rowMarkup row) markup of
        Modify  modify    -> modify
        Keep              -> pure (rowState row)
        -- A row whose widget has to be replaced is left for the next
        -- bind: the cell it sits in is GTK's, and it is not on hand
        -- here.
        Replace _createNew -> pure (rowState row)
      cancelRow <- subscribeRow state markup newState
      modifyIORef'
        (viewRows state)
        (HashMap.insert key row { rowMarkup = markup
                                , rowState  = newState
                                , rowCancel = cancelRow
                                }
        )
