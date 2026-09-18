-- 'controllerName' names its type only in a constraint, and is called
-- with a type application, which is what the first pragma is for.
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

-- | Internal helpers for applying attributes and signal handlers to GTK
-- widgets.
module GI.Gtk.Declarative.Attributes.Internal
  ( addSignalHandler
  , addSignalHandlers
  , addOwnedController
  , runAfterCreated
  , createSlots
  , patchSlots
  , subscribeSlots
  , resolveReferences
  )
where

import           Control.Monad                  ( foldM
                                                , void
                                                )
import           Control.Monad.IO.Class         ( MonadIO
                                                , liftIO
                                                )
import           Data.Coerce                    ( coerce )
import           Data.Foldable                  ( fold
                                                , for_
                                                )
import           Data.GI.Base                   ( GType(..)
                                                , glibType
                                                , withManagedPtr
                                                , gtypeToCGType
                                                , newObject
                                                , withManagedPtr
                                                )
import           Data.HashMap.Strict            ( HashMap )
import qualified Data.HashMap.Strict           as HashMap
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified Data.GI.Base.Signals          as Signals
import           Foreign.Ptr                    ( Ptr
                                                , castPtr
                                                , nullPtr
                                                , ptrToWordPtr
                                                , wordPtrToPtr
                                                )
import qualified GI.GLib                       as GLib
import qualified GI.GObject                    as GI
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Attributes.Internal.Conversions
import           GI.Gtk.Declarative.Container.Class
                                                ( childWidgets )
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.State

-- | Subscribe to everything an attribute list asks for: the widget's
-- own signals, and the event controllers.
--
-- The controllers are the reason this takes the whole list rather than
-- one attribute at a time. A controller is kept on the widget across a
-- patch, and which controller is which is its place in this list, so
-- the list has to be walked in order. Anything the list no longer asks
-- for is taken off the widget at the end.
addSignalHandlers
  :: (Gtk.IsWidget widget, MonadIO m)
  => (event -> IO ())
  -> widget
  -> Vector (Attribute widget event)
  -> m Subscription
addSignalHandlers onEvent widget' attributes = liftIO $ do
  w                     <- Gtk.toWidget widget'
  (subscriptions, slots) <- foldM step (mempty, 0) (Vector.toList attributes)
  pruneControllers w slots
  pure subscriptions
 where
  step (subscriptions, slots) = \case
    OnControllerPure newController signal handler -> do
      subscription <- addController widget'
                                    slots
                                    newController
                                    signal
                                    (toGtkCallback handler widget' onEvent)
      pure (subscriptions <> subscription, slots + 1)
    OnControllerImpure newController signal handler -> do
      subscription <- addController widget'
                                    slots
                                    newController
                                    signal
                                    (toGtkCallback handler widget' onEvent)
      pure (subscriptions <> subscription, slots + 1)
    attribute -> do
      subscription <- addSignalHandler onEvent widget' attribute
      pure (subscriptions <> subscription, slots)

addSignalHandler
  :: (Gtk.IsWidget widget, MonadIO m)
  => (event -> IO ())
  -> widget
  -> Attribute widget event
  -> m Subscription
addSignalHandler onEvent widget' = \case
  OnSignalPure signal handler -> do
    handlerId <- Gtk.on widget' signal (toGtkCallback handler widget' onEvent)
    w         <- Gtk.toWidget widget'
    pure (fromCancellation (GI.signalHandlerDisconnect w handlerId))
  OnSignalImpure signal handler -> do
    handlerId <- Gtk.on widget' signal (toGtkCallback handler widget' onEvent)
    w         <- Gtk.toWidget widget'
    pure (fromCancellation (GI.signalHandlerDisconnect w handlerId))
  _ -> pure mempty

-- | Put an event controller on a widget, and connect one of its
-- signals for as long as the subscription lasts.
--
-- The controller itself outlives the subscription. An application
-- cancels and subscribes again on every event, and a controller that
-- was taken off and put back would lose what it had counted: a
-- 'Gtk.GestureClick' counts the presses of a double click, and a new
-- gesture has counted none, so the second click of every double click
-- would arrive as a first. What the subscription owns is the handler
-- behind the controller, which is connected here and disconnected when
-- it is cancelled.
--
-- Which controller is which is its slot: its place among the
-- controllers in the attribute list. A slot holds one kind of
-- controller, so a slot that is asked for a controller of another type
-- is emptied and filled again.
addController
  :: forall widget controller info m
   . ( Gtk.IsWidget widget
     , Gtk.IsEventController controller
     , Signals.SignalInfo info
     , MonadIO m
     )
  => widget
  -> Int
  -> IO controller
  -> Gtk.SignalProxy controller info
  -> Signals.HaskellCallbackType info
  -> m Subscription
addController widget' slot' newController signal callback = liftIO $ do
  w      <- Gtk.toWidget widget'
  wanted <- glibType @controller
  found  <- lookupController w slot'
  kept   <- case found of
    Just (existing, gtype) | gtype == wanted -> pure existing
    Just (existing, _) -> do
      -- The slot holds a controller of another kind, which is this
      -- attribute list asking for something else than the one before.
      Gtk.widgetRemoveController w existing
      forgetController w slot'
      freshController widget' w slot' wanted newController
    Nothing -> freshController widget' w slot' wanted newController
  handlerId <- Gtk.on (asController kept :: controller) signal callback
  pure (fromCancellation (GI.signalHandlerDisconnect kept handlerId))

-- | Add an event controller to a widget, and answer with a reference
-- the caller still owns.
--
-- A widget takes a controller over when it is given one, so the value
-- that was handed in is a value nobody owns, and reading it again is
-- what the bindings warn about at run time. This hands back a
-- reference that is owned, for a custom widget that has to reach its
-- controllers after it has added them.
--
-- The controller is the caller's from then on, and this library leaves
-- it alone: a controller it did not put there is in none of its slots.
addOwnedController
  :: (Gtk.IsWidget widget, Gtk.IsEventController controller, MonadIO m)
  => widget
  -> controller
  -> m controller
addOwnedController widget' controller = liftIO $ do
  -- Read while the value is still the caller's. The pointer stays good
  -- because the widget holds the controller from here on.
  address <- withManagedPtr controller (pure . castPtr)
  Gtk.widgetAddController widget' controller
  asController <$> ownedController address

-- | Make a controller, put it on the widget, and write down where it
-- is.
freshController
  :: (Gtk.IsWidget widget, Gtk.IsEventController controller)
  => widget
  -> Gtk.Widget
  -> Int
  -> GType
  -> IO controller
  -> IO Gtk.EventController
freshController widget' w slot' gtype newController = do
  fresh <- newController
  name  <- controllerName gtype slot'
  Gtk.eventControllerSetName fresh (Just name)
  -- Read while the value is still ours: the widget takes the
  -- controller over, and reading it afterwards is what the bindings
  -- warn about. The pointer stays good because the widget holds it.
  address <- withManagedPtr fresh (pure . castPtr)
  Gtk.widgetAddController widget' fresh
  rememberController w slot' address gtype
  ownedController address

-- | A controller found on a widget, at the type the attribute asks
-- for.
--
-- Sound because of where the value comes from: the slot it was found
-- in was asked for a controller of this type, and a slot holding one
-- of another type is emptied above rather than read.
asController
  :: Gtk.IsEventController controller => Gtk.EventController -> controller
asController = coerce

-- | What this library calls the controller in a slot, which is what a
-- person looking at the widget in an inspector reads. The library
-- itself finds a controller by its slot rather than by this name.
controllerName :: GType -> Int -> IO Text
controllerName gtype slot' = do
  name <- GI.typeName gtype
  pure
    (controllerPrefix <> Text.pack (show slot') <> "-" <> maybe "" id name)

controllerPrefix :: Text
controllerPrefix = "gi-gtk4-declarative-controller-"

--
-- Where a widget's controllers are written down
--
-- A controller has to be found again on every render, and walking the
-- widget's controllers to find it costs a list of wrappers and a name
-- for each one, every time. So the widget is told where its
-- controllers are, under a key per slot, which answers in one lookup.
--
-- A controller somebody else put on the widget is in no slot, and is
-- left alone. A controller this library put there and somebody else
-- took off would leave the slot pointing at nothing, so taking one off
-- by hand is not something to do.
--

slotKey :: Int -> Text
slotKey slot' = controllerPrefix <> Text.pack (show slot')

slotTypeKey :: Int -> Text
slotTypeKey slot' = slotKey slot' <> "-type"

-- | The controller in this slot, and the type it was made at.
lookupController :: Gtk.Widget -> Int -> IO (Maybe (Gtk.EventController, GType))
lookupController widget' slot' = do
  address <- GI.objectGetData widget' (slotKey slot')
  if address == nullPtr
    then pure Nothing
    else do
      controller <- ownedController address
      stored     <- GI.objectGetData widget' (slotTypeKey slot')
      pure (Just (controller, GType (fromIntegral (ptrToWordPtr stored))))

-- | A reference of our own to the controller at this address, which is
-- alive for as long as the widget holds it.
ownedController :: Ptr () -> IO Gtk.EventController
ownedController address =
  newObject Gtk.EventController (castPtr address :: Ptr Gtk.EventController)

rememberController :: Gtk.Widget -> Int -> Ptr () -> GType -> IO ()
rememberController widget' slot' address gtype = do
  GI.objectSetData widget' (slotKey slot') address
  GI.objectSetData widget'
                   (slotTypeKey slot')
                   (wordPtrToPtr (fromIntegral (gtypeToCGType gtype)))

forgetController :: Gtk.Widget -> Int -> IO ()
forgetController widget' slot' = do
  GI.objectSetData widget' (slotKey slot') nullPtr
  GI.objectSetData widget' (slotTypeKey slot') nullPtr

-- | Take off the controllers in the slots this render did not fill,
-- which are the ones the attributes no longer ask for.
pruneControllers :: Gtk.Widget -> Int -> IO ()
pruneControllers widget' from = do
  found <- lookupController widget' from
  for_ found $ \(controller, _) -> do
    Gtk.widgetRemoveController widget' controller
    forgetController widget' from
    pruneControllers widget' (from + 1)

-- | Run what the attributes asked to have run once the widget is
-- built. Creation only: a patch leaves these alone.
runAfterCreated
  :: MonadIO m => widget -> Vector (Attribute widget event) -> m ()
runAfterCreated widget' attributes = liftIO $ for_ attributes $ \attribute ->
  case attribute of
    AfterCreated action -> action widget'
    _                   -> pure ()

--
-- Widget-valued properties
--

-- | Create the widgets for a widget's widget-valued properties, and put
-- them in place.
createSlots
  :: Gtk.IsWidget widget
  => widget
  -> Vector (Attribute widget event)
  -> IO (HashMap Text SomeState)
createSlots widget' attributes = traverse fill (collectSlots attributes)
 where
  fill (setter, child) = do
    state <- create child
    setter widget' . Just =<< someStateWidget state
    pure state

-- | Patch the widgets in a widget's widget-valued properties. A slot
-- the new attributes no longer name is emptied.
patchSlots
  :: Gtk.IsWidget widget
  => widget
  -> HashMap Text SomeState
  -> Vector (Attribute widget e1)
  -> Vector (Attribute widget e2)
  -> IO (HashMap Text SomeState)
patchSlots widget' states oldAttributes newAttributes = do
  let old = collectSlots oldAttributes
      new = collectSlots newAttributes
  for_ (HashMap.difference old new) $ \(setter, _) -> setter widget' Nothing
  HashMap.traverseWithKey (patchSlot old) new
 where
  patchSlot old name (setter, newChild) =
    case (HashMap.lookup name states, HashMap.lookup name old) of
      (Just state, Just (_, oldChild)) -> case patch state oldChild newChild of
        Modify  modify    -> modify
        Replace createNew -> fill setter createNew
        Keep              -> pure state
      -- A slot that was not filled before.
      _ -> fill setter (create newChild)
  fill setter createNew = do
    state <- createNew
    setter widget' . Just =<< someStateWidget state
    pure state

-- | Subscribe to the widgets in a widget's widget-valued properties.
subscribeSlots
  :: HashMap Text SomeState
  -> Vector (Attribute widget event)
  -> (event -> IO ())
  -> IO Subscription
subscribeSlots states attributes cb =
  fold <$> HashMap.traverseWithKey subscribeSlot (collectSlots attributes)
 where
  subscribeSlot name (_, child) = case HashMap.lookup name states of
    Just state -> subscribe child state cb
    Nothing    -> pure mempty

--
-- References to other widgets
--

-- | Point this widget's references at the widgets they name.
--
-- The widget being pointed at is somewhere else in the tree, and at the
-- time this widget is made that tree is still being built: this widget
-- does not even have a parent yet. So the work is left for the main
-- loop to pick up, by which time the tree is whole.
resolveReferences
  :: (Gtk.IsWidget widget, MonadIO m)
  => widget
  -> Vector (Attribute widget event)
  -> m ()
resolveReferences widget' attributes = for_ attributes $ \attribute ->
  case attribute of
    Reference setter name ->
      void $ GLib.idleAdd GLib.PRIORITY_DEFAULT $ do
        target <- findNamed widget' name
        case target of
          Nothing -> GLib.logDefaultHandler
            (Just "gi-gtk4-declarative")
            [GLib.LogLevelFlagsLevelWarning]
            (Just ("There is no widget named " <> name <> " to point at."))
            nullPtr
          Just _ -> pure ()
        setter widget' target
        pure False
    _ -> pure ()

-- | Look through the widgets under this one's root for one with this
-- name. A widget with no name of its own answers with the name of its
-- class, so a name to point at is best made a distinctive one.
findNamed :: Gtk.IsWidget widget => widget -> Text -> IO (Maybe Gtk.Widget)
findNamed widget' name = do
  root <- topmost =<< Gtk.toWidget widget'
  search root
 where
  topmost w = do
    parent <- Gtk.widgetGetParent w
    maybe (pure w) topmost parent
  search w = do
    thisName <- Gtk.widgetGetName w
    if thisName == name
      then pure (Just w)
      else do
        children <- childWidgets w
        firstOf (Vector.toList children)
  firstOf []       = pure Nothing
  firstOf (w : ws) = do
    found <- search w
    maybe (firstOf ws) (pure . Just) found
