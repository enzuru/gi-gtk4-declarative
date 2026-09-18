{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedLabels      #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

-- | A declarative @AdwToggleGroup@: one choice out of a few.
--
-- @
-- toggleGroup []
--   defaultToggleGroupParams
--     { toggles     = [toggle "9" "9x9", toggle "13" "13x13", toggle "19" "19x19"]
--     , active      = Just (sizeName state)
--     , onActivated = Just Chose
--     }
-- @
--
-- Each toggle has a name of its own, which is what says which one is
-- chosen, and what matches one render with the next.
--
-- A toggle group is not a container, because what it holds are
-- @AdwToggle@ objects rather than widgets. They are described here
-- instead, as data.
--
-- == Why this rather than toggle buttons
--
-- A row of 'GI.Gtk.ToggleButton's whose @active@ comes from the markup
-- does not hold together. The markup says a button is on, somebody
-- clicks it, and GTK turns it off. The next render says what it said
-- before, so the value the markup declares has not changed, the patch
-- sets nothing, and the button stays off. The markup and the screen
-- disagree from then on.
--
-- A toggle group has one @active@ for the whole group, and GTK will not
-- let a click turn the chosen one off, so that route is closed. This
-- widget closes the other one as well: 'active' is read back off the
-- group before it is set, so a group that has drifted from what the
-- markup says is put back however it got there.
module GI.Gtk.Declarative.Adwaita.ToggleGroup
  ( ToggleGroup
  , Toggle(..)
  , toggle
  , ToggleGroupParams(..)
  , defaultToggleGroupParams
  , toggleGroup
  )
where

import           Control.Exception              ( finally )
import           Control.Monad                  ( unless
                                                , when
                                                )
import           Data.Foldable                  ( for_ )
import           Data.IORef
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

-- | One of the choices in a toggle group.
data Toggle = Toggle
  { toggleName     :: Text
  -- ^ Which choice this is. It is what 'active' names, what
  -- 'onActivated' answers with, and what matches this toggle with the
  -- one of the render before.
  , toggleLabel    :: Maybe Text
  , toggleIconName :: Maybe Text
  , toggleTooltip  :: Maybe Text
  , toggleEnabled  :: Bool
  }
  deriving (Eq, Show)

-- | A toggle with a name and a label. The rest take their usual
-- values: no icon, no tooltip, and enabled.
toggle :: Text -> Text -> Toggle
toggle name label = Toggle { toggleName     = name
                           , toggleLabel    = Just label
                           , toggleIconName = Nothing
                           , toggleTooltip  = Nothing
                           , toggleEnabled  = True
                           }

-- | The choices, which one is chosen, and what to do when somebody
-- chooses another.
data ToggleGroupParams event = ToggleGroupParams
  { toggles     :: Vector Toggle
  , active      :: Maybe Text
  -- ^ The name of the chosen toggle. This is a property rather than a
  -- command: the group is put back to it whenever the two disagree, so
  -- what the markup says is what is on the screen. 'Nothing' leaves
  -- the choice to the group.
  , onActivated :: Maybe (Text -> event)
  -- ^ Emitted with the name of the toggle somebody chose. A choice
  -- this markup asked for does not emit.
  }
  deriving (Functor)

-- | A group with no toggles, which emits nothing.
defaultToggleGroupParams :: ToggleGroupParams event
defaultToggleGroupParams = ToggleGroupParams { toggles     = mempty
                                             , active      = Nothing
                                             , onActivated = Nothing
                                             }

-- | A declarative toggle group. As with the model views, the events
-- the markup emits and the events the group is read as are two types
-- with a function between them, so that 'fmap' leaves the state alone.
data ToggleGroup event where
  ToggleGroup
    ::Typeable inner
    => Vector (Attribute Adw.ToggleGroup inner)
    -> ToggleGroupParams inner
    -> (inner -> event)
    -> ToggleGroup event

instance Functor ToggleGroup where
  fmap f (ToggleGroup attributes params toEvent) =
    ToggleGroup attributes params (f . toEvent)

-- | A toggle group is a widget of its own rather than a widget over
-- something else, so it says how it converts to a 'Widget' itself.
instance FromWidget ToggleGroup Widget where
  fromWidget = Widget

-- | Construct a toggle group from attributes and parameters.
toggleGroup
  :: (Typeable event, FromWidget ToggleGroup target)
  => Vector (Attribute Adw.ToggleGroup event)
  -> ToggleGroupParams event
  -> target event
toggleGroup attributes params =
  fromWidget (ToggleGroup attributes params id)

--
-- What the group keeps between renders
--

data ToggleGroupState event = ToggleGroupState
  { stateToggles     :: IORef (Vector (Text, Adw.Toggle))
  -- ^ The toggle objects in the group, by name, in the order they are
  -- in.
  , stateSink        :: IORef (event -> IO ())
  , stateOnActivated :: IORef (Maybe (Text -> event))
  , stateQuiet       :: IORef Bool
  -- ^ True while this library is the one changing the group. GTK tells
  -- a group about every change, its own included, and a render is not
  -- news to the program that asked for it.
  }

newToggleGroupState :: ToggleGroupParams event -> IO (ToggleGroupState event)
newToggleGroupState params =
  ToggleGroupState
    <$> newIORef mempty
    <*> newIORef noSink
    <*> newIORef (onActivated params)
    <*> newIORef False

noSink :: event -> IO ()
noSink _ = pure ()

quietly :: ToggleGroupState event -> IO a -> IO a
quietly state action = do
  writeIORef (stateQuiet state) True
  action `finally` writeIORef (stateQuiet state) False

--
-- Patchable
--

instance Patchable ToggleGroup where
  create (ToggleGroup attributes params _toEvent) = do
    let collected = collectAttributes attributes
    group <- Gtk.new Adw.ToggleGroup (constructProperties collected)
    updateClasses group mempty (collectedClasses collected)
    slots <- createSlots group attributes
    resolveReferences group attributes

    state <- newToggleGroupState params
    connectSignals group state
    quietly state $ do
      applyToggles group state (toggles params)
      applyActive group (active params)
    runAfterCreated group attributes

    pure
      (SomeState (StateTreeWidget (StateTreeNode group collected state slots)))

  patch (SomeState (st :: StateTree stateType w1 c1 e1 cs)) (ToggleGroup oldAttributes _ _) new@(ToggleGroup (newAttributes :: Vector (Attribute Adw.ToggleGroup inner)) newParams _)
    = case (st, eqT @w1 @Adw.ToggleGroup, eqT @cs @(ToggleGroupState inner)) of
      (StateTreeWidget top, Just Refl, Just Refl) ->
        let oldCollected      = stateTreeCollectedAttributes top
            newCollected      = collectAttributes newAttributes
            oldCollectedProps = collectedProperties oldCollected
            newCollectedProps = collectedProperties newCollected
        in  if oldCollectedProps `canBeModifiedTo` newCollectedProps
              then Modify $ do
                let group = stateTreeWidget top
                    state = stateTreeCustomState top
                updateProperties group oldCollectedProps newCollectedProps
                updateClasses group
                              (collectedClasses oldCollected)
                              (collectedClasses newCollected)
                slots <- patchSlots group
                                    (stateTreeSlots top)
                                    oldAttributes
                                    newAttributes
                resolveReferences group newAttributes

                writeIORef (stateOnActivated state) (onActivated newParams)
                quietly state $ do
                  applyToggles group state (toggles newParams)
                  applyActive group (active newParams)

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

instance EventSource ToggleGroup where
  subscribe (ToggleGroup (attributes :: Vector (Attribute Adw.ToggleGroup inner)) _ toEvent) (SomeState (st :: StateTree stateType w c e cs)) cb
    = case (st, eqT @cs @(ToggleGroupState inner)) of
      (StateTreeWidget top, Just Refl) -> do
        let state = stateTreeCustomState top
            sink  = cb . toEvent
        writeIORef (stateSink state) sink
        group     <- Gtk.unsafeCastTo Adw.ToggleGroup (stateTreeWidget top)
        handlers' <- addSignalHandlers sink group attributes
        slots     <- subscribeSlots (stateTreeSlots top) attributes sink
        pure
          (  handlers'
          <> slots
          <> fromCancellation (writeIORef (stateSink state) noSink)
          )
      _ -> pure mempty

--
-- The toggles, the choice, and the signal
--

connectSignals :: Adw.ToggleGroup -> ToggleGroupState event -> IO ()
connectSignals group state = do
  _ <- Gtk.on group (Gtk.PropertyNotify #activeName) $ \_pspec -> do
    quiet <- readIORef (stateQuiet state)
    unless quiet $ do
      chosen  <- Adw.toggleGroupGetActiveName group
      emitted <- readIORef (stateOnActivated state)
      for_ ((,) <$> chosen <*> emitted) $ \(name, make) -> do
        sink <- readIORef (stateSink state)
        sink (make name)
  pure ()

-- | Bring the toggles in line with the ones asked for.
--
-- A group whose toggles are the same names in the same order keeps the
-- objects it has, and their labels and the rest are set again on them.
-- Anything else is made from the beginning, because a toggle holds
-- nothing but what the markup says: which one is chosen belongs to the
-- group, and is put back afterwards.
applyToggles
  :: Adw.ToggleGroup -> ToggleGroupState event -> Vector Toggle -> IO ()
applyToggles group state wanted = do
  before <- readIORef (stateToggles state)
  if fmap fst before == fmap toggleName wanted
    then Vector.zipWithM_ (\(_, made) spec -> applyToggle spec made)
                          before
                          wanted
    else do
      Adw.toggleGroupRemoveAll group
      made <- traverse (newToggle group) wanted
      writeIORef (stateToggles state) (Vector.mapMaybe id made)

-- | Make a toggle, put it in the group, and take back a reference to
-- it.
--
-- The group takes the toggle over when it is given one, so the value
-- that went in is nobody's afterwards. The one that comes back out of
-- the group by name is the group's to give.
newToggle :: Adw.ToggleGroup -> Toggle -> IO (Maybe (Text, Adw.Toggle))
newToggle group spec = do
  made <- Gtk.new Adw.Toggle []
  applyToggle spec made
  Adw.toggleGroupAdd group made
  found <- Adw.toggleGroupGetToggleByName group (toggleName spec)
  pure (fmap ((,) (toggleName spec)) found)

applyToggle :: Toggle -> Adw.Toggle -> IO ()
applyToggle spec made = do
  Adw.toggleSetName made (Just (toggleName spec))
  Adw.toggleSetLabel made (toggleLabel spec)
  Adw.toggleSetIconName made (toggleIconName spec)
  for_ (toggleTooltip spec) (Adw.toggleSetTooltip made)
  Adw.toggleSetEnabled made (toggleEnabled spec)

-- | Put the group back to the choice the markup names, whenever the
-- two disagree.
--
-- This is read before it is written, unlike the commands of the model
-- views, and that is the point of it. A group that somebody has
-- changed says something the markup does not, and the next render is
-- what puts it right, even though the markup says what it said before.
applyActive :: Adw.ToggleGroup -> Maybe Text -> IO ()
applyActive group chosen = for_ chosen $ \name -> do
  known <- Adw.toggleGroupGetToggleByName group name
  for_ known $ \_ -> do
    current <- Adw.toggleGroupGetActiveName group
    when (current /= Just name) (Adw.toggleGroupSetActiveName group (Just name))
