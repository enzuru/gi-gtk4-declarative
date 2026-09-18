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

-- | A declarative 'Gtk.ListView'.
--
-- A list view shows one widget per row, and builds those widgets only
-- for the rows on screen, reusing them as the list scrolls. So it takes
-- the rows as data and a function that renders one, rather than a list
-- of child widgets:
--
-- @
-- listView []
--   (defaultListViewParams (\\name -> widget Gtk.Label [#label := name]))
--     { rows = names
--     , onActivated = Just Chose
--     }
-- @
--
-- The rows stay in Haskell. What GTK holds is one stand-in object per
-- row, and a bind looks the row up here, so a list of a hundred
-- thousand costs a hundred thousand small objects and however many
-- widgets fit on the screen.
--
-- Put the view in a 'Gtk.ScrolledWindow'. A list view does not scroll
-- on its own.
--
-- A view whose rows are not a choice asks for no selection at all:
--
-- @
-- (defaultListViewParams renderRow) { rows = items, selectionMode = SelectNothing }
-- @
--
-- The parameters of a list view and of a column view share field
-- names, so a module that uses both wants either
-- @DisambiguateRecordFields@ or a qualified import of one of them.
module GI.Gtk.Declarative.ModelView.ListView
  ( ListView
  , ListViewParams(..)
  , defaultListViewParams
  , listView
  , SelectionMode(..)
  )
where

import           Control.Monad                  ( when )
import           Data.Foldable                  ( for_ )
import qualified Data.HashMap.Strict           as HashMap
import           Data.IORef
import           Data.Typeable
import           Data.Vector                    ( Vector )
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Attributes.Collected
import           GI.Gtk.Declarative.Attributes.Internal
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.ModelView.Internal
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.Widget

-- | The rows of a list view, how to render one, and what to do about
-- the selection.
data ListViewParams item event = ListViewParams
  { rows        :: Vector item
  -- ^ The rows, as data.
  , renderRow   :: item -> Widget event
  -- ^ Renders one row. Called when a row comes on screen, and again
  -- when the row it shows changes.
  , selected    :: Maybe Word
  -- ^ Select this row. Carried out when the value differs from the one
  -- given last time, so repeating it does nothing.
  , scrollTo    :: Maybe Word
  -- ^ Scroll to this row, on the same terms as 'selected'.
  , onSelected  :: Maybe (Word -> event)
  -- ^ Emitted when the selected row changes, whoever changed it.
  , onActivated :: Maybe (Word -> event)
  -- ^ Emitted when a row is activated, by a double click or by Enter.
  , rowUnchanged :: Maybe (item -> item -> Bool)
  -- ^ Whether a row that is on screen can be left as it is, given the
  -- item it was drawn from and the item it would be drawn from now.
  -- @Just (==)@ is the usual answer, and the one to give: a patch then
  -- draws the rows whose items changed rather than every row on
  -- screen, which is most of the cost of patching a view of any size.
  --
  -- 'Nothing', which is what this starts as, draws every row on screen
  -- again on every patch. That is what a 'renderRow' which reads
  -- something other than its item needs, because then two equal items
  -- do not mean two equal rows.
  , selectionMode :: SelectionMode
  -- ^ Whether a row can be selected at all. Under 'SelectNothing',
  -- 'selected' and 'onSelected' do nothing. Changing this between
  -- renders builds the view again, because the selection model is one
  -- GTK object or the other.
  }
  deriving (Functor)

-- | A list view showing nothing yet, rendered by this function.
defaultListViewParams :: (item -> Widget event) -> ListViewParams item event
defaultListViewParams render = ListViewParams
  { rows          = mempty
  , renderRow     = render
  , selected      = Nothing
  , scrollTo      = Nothing
  , onSelected    = Nothing
  , onActivated   = Nothing
  , rowUnchanged  = Nothing
  , selectionMode = SelectOne
  }

-- | A declarative list view.
--
-- The events the markup emits and the events the view is read as are
-- two types, with a function between them. The state a view keeps has
-- to name the type of the events its rows emit, and that type has to
-- stay put while 'fmap' changes what the view is read as, which it
-- could not do if the two were one type.
data ListView item event where
  ListView
    ::(Typeable item, Typeable inner)
    => Vector (Attribute Gtk.ListView inner)
    -> ListViewParams item inner
    -> (inner -> event)
    -> ListView item event

instance Functor (ListView item) where
  fmap f (ListView attributes params toEvent) =
    ListView attributes params (f . toEvent)

-- | Construct a list view from attributes and parameters.
listView
  :: ( Typeable item
     , Typeable event
     , FromWidget (ListView item) target
     )
  => Vector (Attribute Gtk.ListView event)
  -> ListViewParams item event
  -> target event
listView attributes params = fromWidget (ListView attributes params id)

--
-- Patchable
--

instance Patchable (ListView item) where
  create (ListView attributes params _toEvent) = do
    let collected = collectAttributes attributes
    view  <- Gtk.new Gtk.ListView (constructProperties collected)
    updateClasses view mempty (collectedClasses collected)
    slots <- createSlots view attributes
    resolveReferences view attributes

    state <- newViewState (selectionMode params)
                          (rows params)
                          (HashMap.singleton theColumn (renderRow params))
    writeIORef (viewOnSelected state)  (onSelected params)
    writeIORef (viewOnActivated state) (onActivated params)
    writeIORef (viewUnchanged state)   (rowUnchanged params)

    factory <- Gtk.signalListItemFactoryNew
    connectFactory state factory
    -- Set rather than passed to the constructor: gtk_list_view_new
    -- takes the model and the factory over, and the values here would
    -- be left disowned.
    Gtk.listViewSetFactory view (Just factory)
    Gtk.listViewSetModel view . Just =<< selectionModel (viewSelection state)
    connectSelection state view
    applyCommands state view params
    runAfterCreated view attributes

    pure
      (SomeState (StateTreeWidget (StateTreeNode view collected state slots)))

  patch (SomeState (st :: StateTree stateType w1 c1 e1 cs)) (ListView oldAttributes _ _) new@(ListView (newAttributes :: Vector (Attribute Gtk.ListView inner)) newParams _)
    = case (st, eqT @w1 @Gtk.ListView, eqT @cs @(ViewState item inner)) of
      (StateTreeWidget top, Just Refl, Just Refl) ->
        let oldCollected      = stateTreeCollectedAttributes top
            newCollected      = collectAttributes newAttributes
            oldCollectedProps = collectedProperties oldCollected
            newCollectedProps = collectedProperties newCollected
            sameSelection =
              selectionModeOf (viewSelection (stateTreeCustomState top))
                == selectionMode newParams
        in  if oldCollected `canBeModifiedTo` newCollected
              && sameSelection
              then Modify $ do
                let view  = stateTreeWidget top
                    state = stateTreeCustomState top
                updateProperties view oldCollectedProps newCollectedProps
                updateOtherProperties view oldCollected newCollected
                updateClasses view
                              (collectedClasses oldCollected)
                              (collectedClasses newCollected)
                slots <- patchSlots view
                                    (stateTreeSlots top)
                                    oldAttributes
                                    newAttributes
                resolveReferences view newAttributes

                writeIORef (viewRenderers state)
                           (HashMap.singleton theColumn (renderRow newParams))
                writeIORef (viewOnSelected state)  (onSelected newParams)
                writeIORef (viewOnActivated state) (onActivated newParams)
                writeIORef (viewUnchanged state)   (rowUnchanged newParams)
                setItems state (rows newParams)
                -- The rows on screen show the items they showed before
                -- until they are told otherwise: the model has not
                -- changed, so GTK has no reason to bind them again.
                rebindRows state
                applyCommands state view newParams

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

instance EventSource (ListView item) where
  subscribe (ListView (attributes :: Vector (Attribute Gtk.ListView inner)) _ toEvent) (SomeState (st :: StateTree stateType w c e cs)) cb
    = case (st, eqT @cs @(ViewState item inner)) of
      (StateTreeWidget top, Just Refl) -> do
        let state = stateTreeCustomState top
            sink  = cb . toEvent
        -- The rows already publish through this, so they start
        -- emitting without being built again.
        writeIORef (viewSink state) sink
        view     <- Gtk.unsafeCastTo Gtk.ListView (stateTreeWidget top)
        handlers <- addSignalHandlers sink view attributes
        slots    <- subscribeSlots (stateTreeSlots top) attributes sink
        pure
          (  handlers
          <> slots
          <> fromCancellation (writeIORef (viewSink state) noSink)
          )
      _ -> pure mempty

--
-- The factory, the selection, and the commands
--

connectFactory
  :: ViewState item event -> Gtk.SignalListItemFactory -> IO ()
connectFactory state factory = do
  _ <- Gtk.on factory #bind
    $ withCell (\key cell -> bindCell state theColumn key cell)
  _ <- Gtk.on factory #unbind $ withCell (\key _ -> unbindCell state key)
  _ <- Gtk.on factory #teardown $ withCell (\key _ -> teardownCell state key)
  pure ()
 where
  withCell action object = do
    item <- Gtk.unsafeCastTo Gtk.ListItem object
    key  <- objectKey item
    action key (listItemCell item)

connectSelection :: ViewState item event -> Gtk.ListView -> IO ()
connectSelection state view = do
  case viewSelection state of
    -- Nothing is ever selected under 'SelectNothing', so there is
    -- nothing to hear about.
    SelectionNone _        -> pure ()
    SelectionOne  selection -> do
      _ <- Gtk.on selection (Gtk.PropertyNotify #selected) $ \_pspec -> do
        position <- Gtk.singleSelectionGetSelected selection
        emit state viewOnSelected (fromIntegral position)
      pure ()
  _ <- Gtk.on view #activate
    $ \position -> emit state viewOnActivated (fromIntegral position)
  pure ()

-- | Emit an event from one of the view's own handlers, if the markup
-- gave one and somebody is listening.
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
  :: ViewState item event -> Gtk.ListView -> ListViewParams item event -> IO ()
applyCommands state view params = do
  let new = Commands (selected params) (scrollTo params)
  old <- readIORef (viewCommands state)
  when (commandSelected new /= commandSelected old)
    $ for_ (commandSelected new)
    $ \position -> case viewSelection state of
        SelectionNone _         -> pure ()
        SelectionOne  selection -> Gtk.singleSelectionSetSelected
          selection
          (fromIntegral position)
  when (commandScrollTo new /= commandScrollTo old)
    $ for_ (commandScrollTo new)
    $ \position -> Gtk.listViewScrollTo view (fromIntegral position) [] Nothing
  writeIORef (viewCommands state) new
