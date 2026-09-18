{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}

-- | A declarative @AdwTabView@.
--
-- A tab view holds pages, and a page holds a widget and a title. Each
-- tab carries a key of your own choosing, which is how one render is
-- matched with the next:
--
-- @
-- tabView []
--   defaultTabViewParams
--     { tabs       = [ Tab "first" "First" (widget Gtk.Label [])
--                    , Tab "second" "Second" (widget Gtk.Label [])
--                    ]
--     , selected   = Just "first"
--     , onSelected = Just Chose
--     }
-- @
--
-- A tab that keeps its key keeps its page, and its widget is patched
-- like any other. A key that is new is appended, a key that is gone is
-- closed, and the pages are put in the order the vector is in.
--
-- The view is the tabs and nothing else: an @AdwTabBar@ or an
-- @AdwTabOverview@ is a widget of its own, pointed at this one with
-- @view@, for which "GI.Gtk.Declarative.References" has 'reference'.
--
-- == Closing a tab
--
-- When somebody clicks the close button on a tab, a program usually
-- wants to ask something before the tab goes: whether to save it, say.
-- So a close from the tab's own button is a question rather than an
-- act. The view emits 'onClosePage' with the key and holds the page
-- open. The answer comes back in a later render, in 'closeAnswer', and
-- the page closes then, or stays.
--
-- A view with no 'onClosePage' has nobody to ask, so a close from the
-- button does nothing at all. Taking the tab out of 'tabs' is what
-- closes it, and that never asks.
module GI.Gtk.Declarative.Adwaita.TabView
  ( TabView
  , Tab(..)
  , TabViewParams(..)
  , defaultTabViewParams
  , tabView
  )
where

import           Control.Exception              ( finally )
import           Control.Monad                  ( unless
                                                , when
                                                )
import           Data.Foldable                  ( fold
                                                , for_
                                                )
import           Data.Int                       ( Int32 )
import           Data.IORef
import           Data.Maybe                     ( isNothing )
import           Data.Text                      ( Text )
import           Data.Typeable
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified GI.Adw                        as Adw
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Attributes.Collected
import           GI.Gtk.Declarative.Attributes.Internal
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.Widget

-- | One tab of a tab view.
data Tab event = Tab
  { tabKey   :: Text
  -- ^ Tells this tab from the others across a render. A tab that keeps
  -- its key keeps its page and the state of the widget in it.
  , tabTitle :: Text
  , tabChild :: Widget event
  }
  deriving (Functor)

-- | The tabs of a view, and what to do about them.
data TabViewParams event = TabViewParams
  { tabs        :: Vector (Tab event)
  , selected    :: Maybe Text
  -- ^ Select the tab with this key, when the value differs from the
  -- one before. A command rather than a property: it says what to do
  -- now, not what must hold.
  , onSelected  :: Maybe (Text -> event)
  -- ^ Emitted when somebody else selects a tab. A selection this
  -- markup asked for does not emit.
  , onReordered :: Maybe (Vector Text -> event)
  -- ^ Emitted with all the keys, in their new order, when somebody
  -- drags a tab somewhere else.
  , onClosePage :: Maybe (Text -> event)
  -- ^ Emitted when somebody clicks a tab's close button. The tab stays
  -- until 'closeAnswer' says what to do with it.
  , closeAnswer :: Maybe (Text, Bool)
  -- ^ The answer to the last 'onClosePage': the key that was asked
  -- about, and whether the tab goes. Acted on once, when it arrives.
  }
  deriving (Functor)

-- | A tab view with no tabs, which emits nothing.
defaultTabViewParams :: TabViewParams event
defaultTabViewParams = TabViewParams { tabs        = mempty
                                     , selected    = Nothing
                                     , onSelected  = Nothing
                                     , onReordered = Nothing
                                     , onClosePage = Nothing
                                     , closeAnswer = Nothing
                                     }

-- | A declarative tab view. As with the model views, the events the
-- markup emits and the events the view is read as are two types with a
-- function between them, so that 'fmap' leaves the state alone.
data TabView event where
  TabView
    ::Typeable inner
    => Vector (Attribute Adw.TabView inner)
    -> TabViewParams inner
    -> (inner -> event)
    -> TabView event

instance Functor TabView where
  fmap f (TabView attributes params toEvent) =
    TabView attributes params (f . toEvent)

-- | A tab view is a widget of its own rather than a widget over
-- something else, so it says how it converts to a 'Widget' itself. The
-- instance in the core package is for the widgets that take a type
-- parameter, such as the model views over their items.
instance FromWidget TabView Widget where
  fromWidget = Widget

-- | Construct a tab view from attributes and parameters.
tabView
  :: (Typeable event, FromWidget TabView target)
  => Vector (Attribute Adw.TabView event)
  -> TabViewParams event
  -> target event
tabView attributes params = fromWidget (TabView attributes params id)

--
-- What the view keeps between renders
--

-- | One tab as it stands: the page GTK holds, and the state of the
-- widget in it.
data TabRecord = TabRecord
  { recordKey   :: Text
  , recordPage  :: Adw.TabPage
  , recordState :: SomeState
  }

-- | The handlers of the render that is showing. Kept in a reference,
-- because the signals are connected once and the handlers arrive
-- again with every render.
data Handlers event = Handlers
  { handleSelected  :: Maybe (Text -> event)
  , handleReordered :: Maybe (Vector Text -> event)
  , handleClosePage :: Maybe (Text -> event)
  }

handlersOf :: TabViewParams event -> Handlers event
handlersOf params = Handlers { handleSelected  = onSelected params
                             , handleReordered = onReordered params
                             , handleClosePage = onClosePage params
                             }

data TabViewState event = TabViewState
  { stateRecords  :: IORef (Vector TabRecord)
  -- ^ The tabs in the view, in the order they are in.
  , stateSink     :: IORef (event -> IO ())
  , stateHandlers :: IORef (Handlers event)
  , statePending  :: IORef (Vector (Text, Adw.TabPage))
  -- ^ The closes somebody asked for, waiting for an answer. More than
  -- one at a time, because nothing stops a person clicking the close
  -- button on a second tab while the first is still being asked
  -- about.
  , stateQuiet    :: IORef Bool
  -- ^ True while this library is the one changing the view. GTK tells
  -- a tab view about every change, its own included, and a render is
  -- not news to the program that asked for it.
  , stateSelected :: IORef (Maybe Text)
  -- ^ The last selection this markup asked for.
  }

newTabViewState :: TabViewParams event -> IO (TabViewState event)
newTabViewState params =
  TabViewState
    <$> newIORef mempty
    <*> newIORef noSink
    <*> newIORef (handlersOf params)
    <*> newIORef mempty
    <*> newIORef False
    <*> newIORef Nothing

noSink :: event -> IO ()
noSink _ = pure ()

-- | Do something to the view without hearing about it afterwards.
quietly :: TabViewState event -> IO a -> IO a
quietly state action = do
  writeIORef (stateQuiet state) True
  action `finally` writeIORef (stateQuiet state) False

emit :: TabViewState event -> Maybe event -> IO ()
emit state event = for_ event $ \e -> do
  sink <- readIORef (stateSink state)
  sink e

--
-- Patchable
--

instance Patchable TabView where
  create (TabView attributes params _toEvent) = do
    let collected = collectAttributes attributes
    view  <- Gtk.new Adw.TabView (constructProperties collected)
    updateClasses view mempty (collectedClasses collected)
    slots <- createSlots view attributes
    resolveReferences view attributes

    state <- newTabViewState params
    connectSignals view state
    quietly state $ do
      applyTabs view state mempty (tabs params)
      applySelection view state (selected params)
    runAfterCreated view attributes

    pure
      (SomeState (StateTreeWidget (StateTreeNode view collected state slots)))

  patch (SomeState (st :: StateTree stateType w1 c1 e1 cs)) (TabView oldAttributes oldParams _) new@(TabView (newAttributes :: Vector (Attribute Adw.TabView inner)) newParams _)
    = case (st, eqT @w1 @Adw.TabView, eqT @cs @(TabViewState inner)) of
      (StateTreeWidget top, Just Refl, Just Refl) ->
        let oldCollected      = stateTreeCollectedAttributes top
            newCollected      = collectAttributes newAttributes
            oldCollectedProps = collectedProperties oldCollected
            newCollectedProps = collectedProperties newCollected
        in  if oldCollected `canBeModifiedTo` newCollected
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

                writeIORef (stateHandlers state) (handlersOf newParams)
                quietly state $ do
                  answerPending view state newParams
                  applyTabs view state (tabs oldParams) (tabs newParams)
                  applySelection view state (selected newParams)

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

instance EventSource TabView where
  subscribe (TabView (attributes :: Vector (Attribute Adw.TabView inner)) params toEvent) (SomeState (st :: StateTree stateType w c e cs)) cb
    = case (st, eqT @cs @(TabViewState inner)) of
      (StateTreeWidget top, Just Refl) -> do
        let state = stateTreeCustomState top
            sink  = cb . toEvent
        writeIORef (stateSink state) sink
        view      <- Gtk.unsafeCastTo Adw.TabView (stateTreeWidget top)
        handlers' <- addSignalHandlers sink view attributes
        slots     <- subscribeSlots (stateTreeSlots top) attributes sink
        records   <- readIORef (stateRecords state)
        children  <- fold <$> traverse (subscribeTab sink records) (tabs params)
        pure
          (  handlers'
          <> slots
          <> children
          <> fromCancellation (writeIORef (stateSink state) noSink)
          )
      _ -> pure mempty
   where
    subscribeTab sink records tab =
      case Vector.find ((== tabKey tab) . recordKey) records of
        Just record -> subscribe (tabChild tab) (recordState record) sink
        Nothing     -> pure mempty

--
-- The signals
--

connectSignals :: Adw.TabView -> TabViewState event -> IO ()
connectSignals view state = do
  _ <- Adw.onTabViewClosePage view (closeRequested view state)
  _ <- Adw.onTabViewPageReordered view $ \_page _position ->
    unlessQuiet state $ do
      handlers <- readIORef (stateHandlers state)
      for_ (handleReordered handlers) $ \make -> do
        keys <- currentKeys view state
        emit state (Just (make keys))
  _ <- Gtk.on view (Gtk.PropertyNotify #selectedPage) $ \_pspec ->
    unlessQuiet state $ do
      handlers <- readIORef (stateHandlers state)
      for_ (handleSelected handlers) $ \make -> do
        page    <- Adw.tabViewGetSelectedPage view
        records <- readIORef (stateRecords state)
        for_ page $ \page' ->
          for_ (Vector.find ((== page') . recordPage) records)
            $ \record -> emit state (Just (make (recordKey record)))
  pure ()

unlessQuiet :: TabViewState event -> IO () -> IO ()
unlessQuiet state action = do
  quiet <- readIORef (stateQuiet state)
  unless quiet action

-- | Somebody clicked a tab's close button.
--
-- Returning 'True' stops the default, which is what holds the page
-- open until the program says what to do with it. A view with nobody
-- to ask holds nothing open: it finishes the close with a no, which
-- leaves the page as it was and the button usable again.
closeRequested
  :: Adw.TabView -> TabViewState event -> Adw.TabPage -> IO Bool
closeRequested view state page = do
  quiet <- readIORef (stateQuiet state)
  if quiet
    then pure False
    else do
      records  <- readIORef (stateRecords state)
      handlers <- readIORef (stateHandlers state)
      let asked = Vector.find ((== page) . recordPage) records
      case (asked, handleClosePage handlers) of
        (Just record, Just make) -> do
          modifyIORef' (statePending state)
                       (`Vector.snoc` (recordKey record, page))
          emit state (Just (make (recordKey record)))
          pure True
        _ -> do
          Adw.tabViewClosePageFinish view page False
          pure True

-- | The keys of the pages in the view, in the order the view has them.
currentKeys :: Adw.TabView -> TabViewState event -> IO (Vector Text)
currentKeys view state = do
  records <- readIORef (stateRecords state)
  count   <- Adw.tabViewGetNPages view
  keys    <- traverse (keyOf records) (Vector.enumFromTo 0 (count - 1))
  pure (Vector.concatMap id keys)
 where
  keyOf records index = do
    page <- Adw.tabViewGetNthPage view index
    pure $ case Vector.find ((== page) . recordPage) records of
      Just record -> Vector.singleton (recordKey record)
      Nothing     -> mempty

--
-- The tabs
--

-- | Finish a close somebody asked for, once this render says what to
-- do with it.
--
-- The answer is 'closeAnswer', or the tab being gone from the markup,
-- which says the same thing. A close nothing answers stays open, and
-- is asked about again the next time somebody clicks the button.
answerPending
  :: Adw.TabView -> TabViewState event -> TabViewParams event -> IO ()
answerPending view state params = do
  pending <- readIORef (statePending state)
  writeIORef (statePending state) (Vector.filter (isNothing . answer) pending)
  for_ pending $ \asked@(key, page) -> for_ (answer asked) $ \said -> do
    Adw.tabViewClosePageFinish view page said
    when said $ modifyIORef' (stateRecords state)
                             (Vector.filter ((/= key) . recordKey))
 where
  wanted key = Vector.elem key (fmap tabKey (tabs params))
  answer (key, _) = case closeAnswer params of
    Just (about, said) | about == key -> Just said
    _ | not (wanted key)              -> Just True
    _                                 -> Nothing

-- | Bring the pages in line with the tabs asked for.
--
-- A tab that keeps its key keeps its page, so the widget in it is
-- patched where it stands. A key that is new is appended, and a key
-- that is gone is closed without asking anybody, because the markup
-- has already said so.
applyTabs
  :: Adw.TabView
  -> TabViewState event
  -> Vector (Tab before)
  -> Vector (Tab event)
  -> IO ()
applyTabs view state before wanted = do
  records <- readIORef (stateRecords state)
  let wantedKeys = fmap tabKey wanted
      isWanted r = Vector.elem (recordKey r) wantedKeys
  for_ (Vector.filter (not . isWanted) records) (closePage view . recordPage)
  let kept = Vector.filter isWanted records
  made <- traverse (place kept) wanted
  writeIORef (stateRecords state) made
  -- The pages are in the order they were made in, which is the order
  -- the vector had before this render. Putting them in the order asked
  -- for is a move each, and a move of a page that is already there
  -- costs nothing.
  Vector.imapM_ (\index record -> reorder index (recordPage record)) made
 where
  reorder index page =
    () <$ Adw.tabViewReorderPage view page (fromIntegral index :: Int32)

  place kept tab = case Vector.find ((== tabKey tab) . recordKey) kept of
    Nothing     -> newTab view (tabKey tab) (tabTitle tab) (tabChild tab)
    Just record -> do
      Adw.tabPageSetTitle (recordPage record) (tabTitle tab)
      case Vector.find ((== tabKey tab) . tabKey) before of
        -- A tab whose key is in the view but not in the markup that
        -- built it. Nothing to patch against, so it is made again.
        Nothing -> do
          closePage view (recordPage record)
          newTab view (tabKey tab) (tabTitle tab) (tabChild tab)
        Just old -> case patch (recordState record) (tabChild old) (tabChild tab) of
          Keep     -> pure record
          Modify f -> do
            state' <- f
            pure record { recordState = state' }
          -- A page holds the widget it was made with, so a widget that
          -- has to be replaced is a page that has to be made again.
          Replace f -> do
            closePage view (recordPage record)
            made <- f
            page <- Adw.tabViewAppend view =<< someStateWidget made
            Adw.tabPageSetTitle page (tabTitle tab)
            pure record { recordPage = page, recordState = made }

-- | A page holding a widget of its own.
newTab :: Adw.TabView -> Text -> Text -> Widget event -> IO TabRecord
newTab view key title child = do
  made <- create child
  page <- Adw.tabViewAppend view =<< someStateWidget made
  Adw.tabPageSetTitle page title
  pure TabRecord { recordKey = key, recordPage = page, recordState = made }

-- | Take a page away. This runs while the view is quiet, so the close
-- goes through rather than being asked about.
closePage :: Adw.TabView -> Adw.TabPage -> IO ()
closePage = Adw.tabViewClosePage

-- | Select the tab this render asks for, if it asks for a different
-- one than the render before.
applySelection :: Adw.TabView -> TabViewState event -> Maybe Text -> IO ()
applySelection view state chosen = do
  previous <- readIORef (stateSelected state)
  when (chosen /= previous) $ for_ chosen $ \key -> do
    records <- readIORef (stateRecords state)
    for_ (Vector.find ((== key) . recordKey) records)
      $ \record -> Adw.tabViewSetSelectedPage view (recordPage record)
  writeIORef (stateSelected state) chosen
