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
  , runAfterCreated
  , createSlots
  , patchSlots
  , subscribeSlots
  , resolveReferences
  )
where

import           Control.Monad                  ( foldM
                                                , forM
                                                , void
                                                )
import           Control.Monad.IO.Class         ( MonadIO
                                                , liftIO
                                                )
import           Data.Coerce                    ( coerce )
import           Data.Foldable                  ( fold
                                                , for_
                                                )
import           Data.GI.Base                   ( glibType )
import           Data.List                      ( find )
import           Data.Maybe                     ( catMaybes )
import           Data.HashMap.Strict            ( HashMap )
import qualified Data.HashMap.Strict           as HashMap
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified Data.GI.Base.Signals          as Signals
import           GHC.Ptr                        ( nullPtr )
import qualified GI.GLib                       as GLib
import qualified GI.GObject                    as GI
import qualified GI.Gio                        as Gio
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
  w                    <- Gtk.toWidget widget'
  (subscriptions, kept) <- foldM step (mempty, []) (Vector.toList attributes)
  pruneControllers w kept
  pure subscriptions
 where
  step (subscriptions, kept) = \case
    OnControllerPure newController signal handler -> do
      (subscription, name) <- addController widget'
                                            (length kept)
                                            newController
                                            signal
                                            (toGtkCallback handler widget' onEvent)
      pure (subscriptions <> subscription, kept <> [name])
    OnControllerImpure newController signal handler -> do
      (subscription, name) <- addController widget'
                                            (length kept)
                                            newController
                                            signal
                                            (toGtkCallback handler widget' onEvent)
      pure (subscriptions <> subscription, kept <> [name])
    attribute -> do
      subscription <- addSignalHandler onEvent widget' attribute
      pure (subscriptions <> subscription, kept)

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
-- The name is what ties one render to the next. It says which slot of
-- the attribute list the controller belongs to and what type it has,
-- so a controller is reused only where the same kind of controller is
-- asked for again.
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
  -> m (Subscription, Text)
addController widget' index newController signal callback = liftIO $ do
  w     <- Gtk.toWidget widget'
  name  <- controllerName @controller index
  found <- findController w name
  controller <- case found of
    Just existing -> pure (asController existing)
    Nothing       -> do
      fresh <- newController
      Gtk.eventControllerSetName fresh (Just name)
      Gtk.widgetAddController widget' fresh
      -- The widget took the value over, and reading it again is what
      -- the bindings warn about, so the controller is looked up under
      -- the name it was given.
      added <- findController w name
      pure (maybe fresh asController added)
  handlerId <- Gtk.on controller signal callback
  -- The same object, at the type the disconnect asks for.
  target    <- Gtk.toEventController controller
  pure (fromCancellation (GI.signalHandlerDisconnect target handlerId), name)

-- | A controller found on a widget, at the type the attribute asks
-- for.
--
-- Sound because of where the value comes from: it was found under a
-- name that says its GType, and this library is what put both the
-- controller and the name there.
asController :: Gtk.IsEventController controller => Gtk.EventController -> controller
asController = coerce

-- | What this library calls the controller in this slot: which slot of
-- the attribute list it is, and what type it has. A slot whose
-- controller type changes gets a name of its own, so the controller
-- that is there is replaced rather than reused.
controllerName
  :: forall controller . Gtk.IsEventController controller => Int -> IO Text
controllerName index = do
  gtype <- glibType @controller
  name  <- GI.typeName gtype
  pure
    (  controllerPrefix
    <> Text.pack (show index)
    <> "-"
    <> maybe "unknown" id name
    )

controllerPrefix :: Text
controllerPrefix = "gi-gtk4-declarative-controller-"

-- | The controller on this widget with this name, if it is there.
findController :: Gtk.Widget -> Text -> IO (Maybe Gtk.EventController)
findController widget' name = do
  controllers <- namedControllers widget'
  pure (fst <$> find ((== Just name) . snd) controllers)

-- | Take off the controllers this library put on the widget that the
-- attributes no longer ask for. A controller somebody else added is
-- left alone, which is what the prefix is for.
pruneControllers :: Gtk.Widget -> [Text] -> IO ()
pruneControllers widget' kept = do
  controllers <- namedControllers widget'
  for_ controllers $ \(controller, name) -> case name of
    Just this | controllerPrefix `Text.isPrefixOf` this, this `notElem` kept ->
      Gtk.widgetRemoveController widget' controller
    _ -> pure ()

-- | Every controller on the widget, with the name it goes under.
namedControllers :: Gtk.Widget -> IO [(Gtk.EventController, Maybe Text)]
namedControllers widget' = do
  controllers <- Gtk.widgetObserveControllers widget'
  count       <- Gio.listModelGetNItems controllers
  items       <- if count == 0
    then pure []
    else forM [0 .. count - 1] (Gio.listModelGetItem controllers)
  traverse named (catMaybes items)
 where
  named object = do
    controller <- Gtk.unsafeCastTo Gtk.EventController object
    (,) controller <$> Gtk.eventControllerGetName controller

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
