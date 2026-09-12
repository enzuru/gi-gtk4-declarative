{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}

-- | A declarative 'Gtk.ColumnView'.
--
-- A column view is a list view with more than one cell per row. It
-- takes the rows as data, and a column says how to render one cell of
-- a row:
--
-- @
-- columnView []
--   (defaultColumnViewParams
--     [ column "name" "Name" (\\person -> widget Gtk.Label [#label := name person])
--     , column "age"  "Age"  (\\person -> widget Gtk.Label [#label := age person])
--     ])
--     { rows = people }
-- @
--
-- Each column has a key of your own choosing, which is how one render
-- is matched with the next. A column that keeps its key keeps its
-- widget, its width, and the cells under it, so inserting a column in
-- the middle costs one column rather than all the ones after it.
--
-- Put the view in a 'Gtk.ScrolledWindow'. A column view does not
-- scroll on its own.
--
-- GTK has no factory for column headers, so a header is the title text
-- and nothing else. A program that wants a widget of its own up there
-- still reaches for the header by hand.
--
-- The parameters of a list view and of a column view share field
-- names, so a module that uses both wants either
-- @DisambiguateRecordFields@ or a qualified import of one of them.
module GI.Gtk.Declarative.ModelView.ColumnView
  ( ColumnView
  , ColumnViewParams(..)
  , defaultColumnViewParams
  , Column(..)
  , column
  , columnView
  )
where

import           Control.Monad                  ( when )
import           Data.Foldable                  ( for_ )
import qualified Data.HashMap.Strict           as HashMap
import           Data.Int                       ( Int32 )
import           Data.IORef
import           Data.Char                      ( isAlphaNum )
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Data.Typeable
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified GI.Gio                        as Gio
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Attributes.Collected
import           GI.Gtk.Declarative.Attributes.Internal
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.MenuModel   ( MenuItem
                                                , MenuShape
                                                , buildMenuModel
                                                , menuLeafEvents
                                                , menuShapeOf
                                                )
import           GI.Gtk.Declarative.ModelView.Internal
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.Widget

-- | One column of a column view.
data Column item event = Column
  { columnKey        :: Text
  -- ^ Tells this column from the others across a render. A column that
  -- keeps its key keeps its widget and its width.
  , columnTitle      :: Text
  , columnResizable  :: Bool
  , columnExpand     :: Bool
  -- ^ Whether this column takes the width left over.
  , columnVisible    :: Bool
  , columnFixedWidth :: Maybe Int32
  -- ^ A width to set. Setting it on every render pins the column,
  -- which is not what you want if the user is allowed to resize it:
  -- give it once, or give what the user last left it at.
  , columnHeaderMenu :: Vector (MenuItem event)
  -- ^ A menu on the column's header, for what a person does to a whole
  -- column: insert, remove, move. Empty for no menu. The items are the
  -- declarative ones, so the events behind them arrive like any other.
  , renderCell       :: item -> Widget event
  , onResized        :: Maybe (Int32 -> event)
  -- ^ Emitted when the column's width changes, which is how an
  -- application remembers a layout the user arranged.
  }
  deriving (Functor)

-- | A column with a key, a title, and a way to render a cell. The rest
-- take their usual values: resizable, not expanding, visible, and no
-- width of its own.
column :: Text -> Text -> (item -> Widget event) -> Column item event
column key title render = Column { columnKey        = key
                                 , columnTitle      = title
                                 , columnResizable  = True
                                 , columnExpand     = False
                                 , columnVisible    = True
                                 , columnFixedWidth = Nothing
                                 , columnHeaderMenu = mempty
                                 , renderCell       = render
                                 , onResized        = Nothing
                                 }

-- | The rows of a column view, its columns, and what to do about the
-- selection.
data ColumnViewParams item event = ColumnViewParams
  { rows        :: Vector item
  , columns     :: Vector (Column item event)
  , selected    :: Maybe Word
  -- ^ Select this row, when the value differs from the one before.
  , scrollTo    :: Maybe Word
  -- ^ Scroll to this row, on the same terms.
  , onSelected  :: Maybe (Word -> event)
  , onActivated :: Maybe (Word -> event)
  }
  deriving (Functor)

-- | A column view showing no rows yet, with these columns.
defaultColumnViewParams
  :: Vector (Column item event) -> ColumnViewParams item event
defaultColumnViewParams theColumns = ColumnViewParams { rows        = mempty
                                                      , columns     = theColumns
                                                      , selected    = Nothing
                                                      , scrollTo    = Nothing
                                                      , onSelected  = Nothing
                                                      , onActivated = Nothing
                                                      }

-- | What a column view keeps between patches: the row machinery every
-- view has, and the columns.
data ColumnViewState item event = ColumnViewState
  { columnBase     :: ViewState item event
  , columnRecords  :: IORef (Vector ColumnRecord)
  -- ^ The columns in the view, in the order they are in.
  , columnHandlers :: IORef (HashMap.HashMap Text (Maybe (Int32 -> event)))
  }

data ColumnRecord = ColumnRecord
  { recordKey      :: Text
  , recordColumn   :: Gtk.ColumnViewColumn
  , recordDispatch :: IORef (Int -> IO ())
  -- ^ Where the header menu's actions go. Rewritten on every render,
  -- so that a menu whose shape has not changed still emits this
  -- render's events.
  , recordMenu     :: IORef [MenuShape]
  -- ^ The shape the header menu was last built from. The model is
  -- built again only when this changes.
  }

-- | A declarative column view. As with a list view, the events the
-- markup emits and the events the view is read as are two types with a
-- function between them, so that 'fmap' leaves the state alone.
data ColumnView item event where
  ColumnView
    ::(Typeable item, Typeable inner)
    => Vector (Attribute Gtk.ColumnView inner)
    -> ColumnViewParams item inner
    -> (inner -> event)
    -> ColumnView item event

instance Functor (ColumnView item) where
  fmap f (ColumnView attributes params toEvent) =
    ColumnView attributes params (f . toEvent)

-- | Construct a column view from attributes and parameters.
columnView
  :: (Typeable item, Typeable event, FromWidget (ColumnView item) target)
  => Vector (Attribute Gtk.ColumnView event)
  -> ColumnViewParams item event
  -> target event
columnView attributes params = fromWidget (ColumnView attributes params id)

--
-- Patchable
--

instance Patchable (ColumnView item) where
  create (ColumnView attributes params _toEvent) = do
    let collected = collectAttributes attributes
    view  <- Gtk.new Gtk.ColumnView (constructProperties collected)
    updateClasses view mempty (collectedClasses collected)
    slots <- createSlots view attributes
    resolveReferences view attributes

    base  <- newViewState (rows params) (renderers (columns params))
    state <- ColumnViewState base <$> newIORef mempty <*> newIORef
      (handlers (columns params))
    writeIORef (viewOnSelected base)  (onSelected params)
    writeIORef (viewOnActivated base) (onActivated params)

    -- Set rather than passed to the constructor, which would take the
    -- model over and leave the value here disowned.
    Gtk.columnViewSetModel view (Just (viewSelection base))
    connectSelection base view
    patchColumns view state (columns params)
    applyCommands base view params
    runAfterCreated view attributes

    pure
      (SomeState (StateTreeWidget (StateTreeNode view collected state slots)))

  patch (SomeState (st :: StateTree stateType w1 c1 e1 cs)) (ColumnView oldAttributes _ _) new@(ColumnView (newAttributes :: Vector (Attribute Gtk.ColumnView inner)) newParams _)
    = case (st, eqT @w1 @Gtk.ColumnView, eqT @cs @(ColumnViewState item inner)) of
      (StateTreeWidget top, Just Refl, Just Refl) ->
        let oldCollected      = stateTreeCollectedAttributes top
            newCollected      = collectAttributes newAttributes
            oldCollectedProps = collectedProperties oldCollected
            newCollectedProps = collectedProperties newCollected
        in  if oldCollectedProps `canBeModifiedTo` newCollectedProps
              then Modify $ do
                let view  = stateTreeWidget top
                    state = stateTreeCustomState top
                    base  = columnBase state
                updateProperties view oldCollectedProps newCollectedProps
                updateClasses view
                              (collectedClasses oldCollected)
                              (collectedClasses newCollected)
                slots <- patchSlots view
                                    (stateTreeSlots top)
                                    oldAttributes
                                    newAttributes
                resolveReferences view newAttributes

                writeIORef (viewRenderers base) (renderers (columns newParams))
                writeIORef (columnHandlers state) (handlers (columns newParams))
                writeIORef (viewOnSelected base)  (onSelected newParams)
                writeIORef (viewOnActivated base) (onActivated newParams)
                setItems base (rows newParams)
                patchColumns view state (columns newParams)
                -- The rows on screen still show what they showed
                -- before: the model has not changed, so GTK has no
                -- reason to bind them again.
                rebindRows base
                applyCommands base view newParams

                pure
                  (SomeState
                    (StateTreeWidget top
                      { stateTreeCollectedAttributes = newCollected
                      , stateTreeSlots               = slots
                      }
                    )
                  )
              else Replace (create new)
      _ -> Replace (create new)

--
-- EventSource
--

instance EventSource (ColumnView item) where
  subscribe (ColumnView (attributes :: Vector (Attribute Gtk.ColumnView inner)) _ toEvent) (SomeState (st :: StateTree stateType w c e cs)) cb
    = case (st, eqT @cs @(ColumnViewState item inner)) of
      (StateTreeWidget top, Just Refl) -> do
        let state = stateTreeCustomState top
            sink  = cb . toEvent
        writeIORef (viewSink (columnBase state)) sink
        view     <- Gtk.unsafeCastTo Gtk.ColumnView (stateTreeWidget top)
        handlers' <- foldMap (addSignalHandler sink view) attributes
        slots    <- subscribeSlots (stateTreeSlots top) attributes sink
        pure
          (  handlers'
          <> slots
          <> fromCancellation
               (writeIORef (viewSink (columnBase state)) noSink)
          )
      _ -> pure mempty

--
-- Columns
--

renderers
  :: Vector (Column item event)
  -> HashMap.HashMap Text (item -> Widget event)
renderers =
  HashMap.fromList
    . Vector.toList
    . fmap (\spec -> (columnKey spec, renderCell spec))

handlers
  :: Vector (Column item event)
  -> HashMap.HashMap Text (Maybe (Int32 -> event))
handlers =
  HashMap.fromList
    . Vector.toList
    . fmap (\spec -> (columnKey spec, onResized spec))

-- | Bring the view's columns in line with the ones asked for.
--
-- A column is matched with the one before it by key, which is what
-- makes inserting a column cheap: the ones that keep their keys keep
-- their widgets, their widths, and the cells under them.
patchColumns
  :: Gtk.ColumnView
  -> ColumnViewState item event
  -> Vector (Column item event)
  -> IO ()
patchColumns view state wanted = do
  before <- readIORef (columnRecords state)
  let wantedKeys = fmap columnKey wanted
      isWanted r = recordKey r `Vector.elem` wantedKeys
      kept       = Vector.filter isWanted before
      gone       = Vector.filter (not . isWanted) before
  for_ gone (Gtk.columnViewRemoveColumn view . recordColumn)

  -- The order the kept columns are in, against the order asked for. If
  -- they differ, they are taken out and put back, because GTK has no
  -- way to move a column.
  let keptKeys   = fmap recordKey kept
      wantedKept = Vector.filter (`Vector.elem` keptKeys) wantedKeys
  reordered <- if keptKeys == wantedKept
    then pure kept
    else do
      for_ kept (Gtk.columnViewRemoveColumn view . recordColumn)
      pure mempty

  records <- Vector.imapM (place reordered) wanted
  writeIORef (columnRecords state) records
 where
  place inPlace index spec =
    case Vector.find ((== columnKey spec) . recordKey) inPlace of
      Just record -> do
        applyColumn spec (recordColumn record)
        applyHeaderMenu view state record spec
        pure record
      Nothing -> do
        (made, dispatch) <- newColumn state spec
        Gtk.columnViewInsertColumn view (fromIntegral index) made
        applyColumn spec made
        record <- ColumnRecord (columnKey spec) made dispatch <$> newIORef []
        applyHeaderMenu view state record spec
        pure record

-- | A column, with a factory that renders this column's cells, and the
-- reference its header menu dispatches through.
newColumn
  :: ColumnViewState item event
  -> Column item event
  -> IO (Gtk.ColumnViewColumn, IORef (Int -> IO ()))
newColumn state spec = do
  factory <- Gtk.signalListItemFactoryNew
  let base = columnBase state
      key  = columnKey spec
  _ <- Gtk.on factory #bind
    $ withCell (\cellKey cell -> bindCell base key cellKey cell)
  _ <- Gtk.on factory #unbind $ withCell (\cellKey _ -> unbindCell base cellKey)
  _ <- Gtk.on factory #teardown
    $ withCell (\cellKey _ -> teardownCell base cellKey)
  made <- Gtk.new Gtk.ColumnViewColumn []
  Gtk.columnViewColumnSetFactory made (Just factory)
  _ <- Gtk.on made (Gtk.PropertyNotify #fixedWidth) $ \_pspec -> do
    theHandlers <- readIORef (columnHandlers state)
    case HashMap.lookup key theHandlers of
      Just (Just make) -> do
        width <- Gtk.columnViewColumnGetFixedWidth made
        sink  <- readIORef (viewSink base)
        sink (make width)
      _ -> pure ()
  dispatch <- newIORef (const (pure ()))
  pure (made, dispatch)
 where
  withCell action object = do
    cell    <- Gtk.unsafeCastTo Gtk.ColumnViewCell object
    cellKey <- objectKey cell
    action cellKey (columnViewCell cell)

applyColumn :: Column item event -> Gtk.ColumnViewColumn -> IO ()
applyColumn spec made = do
  Gtk.columnViewColumnSetTitle made (Just (columnTitle spec))
  Gtk.columnViewColumnSetResizable made (columnResizable spec)
  Gtk.columnViewColumnSetExpand made (columnExpand spec)
  Gtk.columnViewColumnSetVisible made (columnVisible spec)
  for_ (columnFixedWidth spec) $ \width -> do
    current <- Gtk.columnViewColumnGetFixedWidth made
    when (current /= width) (Gtk.columnViewColumnSetFixedWidth made width)

-- | Put this column's header menu in place, and point its actions at
-- this render's events.
--
-- The model and its actions are built again only when the shape of the
-- menu changes, as they are for a menu bar. The dispatch is rewritten
-- every time, so that a menu of the same shape still emits the events
-- this render gave.
applyHeaderMenu
  :: Gtk.ColumnView
  -> ColumnViewState item event
  -> ColumnRecord
  -> Column item event
  -> IO ()
applyHeaderMenu view state record spec = do
  let items    = columnHeaderMenu spec
      newShape = menuShapeOf items
      prefix   = menuPrefix (columnKey spec)
  oldShape <- readIORef (recordMenu record)
  when (oldShape /= newShape) $ do
    if Vector.null items
      then do
        Gtk.columnViewColumnSetHeaderMenu (recordColumn record)
                                          (Nothing :: Maybe Gio.MenuModel)
        Gtk.widgetInsertActionGroup view
                                    prefix
                                    (Nothing :: Maybe Gio.SimpleActionGroup)
      else do
        (model, group) <- buildMenuModel prefix (recordDispatch record) items
        Gtk.widgetInsertActionGroup view prefix (Just group)
        Gtk.columnViewColumnSetHeaderMenu (recordColumn record) (Just model)
    writeIORef (recordMenu record) newShape
  writeIORef (recordDispatch record) $ \position ->
    for_ (menuLeafEvents items Vector.!? position) $ \event -> do
      sink <- readIORef (viewSink (columnBase state))
      sink event

-- | The action prefix a column's header menu lives under. A key that
-- is not a plain word is spelled with dashes, because an action prefix
-- is a name rather than free text.
menuPrefix :: Text -> Text
menuPrefix key = "column-menu-" <> Text.map plain key
  where plain c = if isAlphaNum c then c else '-'

--
-- The selection and the commands
--

connectSelection :: ViewState item event -> Gtk.ColumnView -> IO ()
connectSelection state view = do
  _ <- Gtk.on (viewSelection state) (Gtk.PropertyNotify #selected) $ \_pspec ->
    do
      position <- Gtk.singleSelectionGetSelected (viewSelection state)
      emit state viewOnSelected (fromIntegral position)
  _ <- Gtk.on view #activate
    $ \position -> emit state viewOnActivated (fromIntegral position)
  pure ()

emit
  :: ViewState item event
  -> (ViewState item event -> IORef (Maybe (Word -> event)))
  -> Word
  -> IO ()
emit state handler position = do
  toEvent <- readIORef (handler state)
  for_ toEvent $ \make -> do
    sink <- readIORef (viewSink state)
    sink (make position)

applyCommands
  :: ViewState item event
  -> Gtk.ColumnView
  -> ColumnViewParams item event
  -> IO ()
applyCommands state view params = do
  let new = Commands (selected params) (scrollTo params)
  old <- readIORef (viewCommands state)
  when (commandSelected new /= commandSelected old)
    $ for_ (commandSelected new)
    $ \position -> Gtk.singleSelectionSetSelected (viewSelection state)
                                                  (fromIntegral position)
  when (commandScrollTo new /= commandScrollTo old)
    $ for_ (commandScrollTo new)
    $ \position ->
        Gtk.columnViewScrollTo view
                               (fromIntegral position)
                               (Nothing :: Maybe Gtk.ColumnViewColumn)
                               []
                               Nothing
  writeIORef (viewCommands state) new
