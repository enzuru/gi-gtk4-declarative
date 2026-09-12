{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Internal helpers for applying attributes and signal handlers to GTK
-- widgets.
module GI.Gtk.Declarative.Attributes.Internal
  ( addSignalHandler
  , createSlots
  , patchSlots
  , subscribeSlots
  , resolveReferences
  )
where

import           Control.Monad                  ( forM
                                                , void
                                                , when
                                                )
import           Control.Monad.IO.Class         ( MonadIO
                                                , liftIO
                                                )
import           Data.Foldable                  ( fold
                                                , for_
                                                )
import           Data.GI.Base                   ( withManagedPtr )
import           Data.HashMap.Strict            ( HashMap )
import qualified Data.HashMap.Strict           as HashMap
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified Data.GI.Base.Signals          as Signals
import           GHC.Ptr                        ( nullPtr )
import qualified GI.GLib                       as GLib
import qualified GI.GLib.Constants             as GLib
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
  OnControllerPure newController signal handler -> addController
    widget'
    newController
    signal
    (toGtkCallback handler widget' onEvent)
  OnControllerImpure newController signal handler -> addController
    widget'
    newController
    signal
    (toGtkCallback handler widget' onEvent)
  _ -> pure mempty

-- | Add an event controller to a widget, and connect one of its
-- signals.
addController
  :: ( Gtk.IsWidget widget
     , Gtk.IsEventController controller
     , Signals.SignalInfo info
     , MonadIO m
     )
  => widget
  -> IO controller
  -> Gtk.SignalProxy controller info
  -> Signals.HaskellCallbackType info
  -> m Subscription
addController widget' newController signal callback = do
  controller <- liftIO newController
  handlerId  <- Gtk.on controller signal callback
  -- The widget takes the controller over, which leaves the value here
  -- disowned, and reading it again is what the bindings warn about. So
  -- the controller is given a name of its own first, and found by that
  -- name when the time comes to remove it.
  name       <- liftIO (controllerName controller)
  Gtk.eventControllerSetName controller (Just name)
  Gtk.widgetAddController widget' controller
  w <- Gtk.toWidget widget'
  pure (fromCancellation (removeController w name handlerId))

-- | A name no other controller has: the address this one lives at,
-- which is still ours to read before the widget takes it over.
controllerName :: Gtk.IsEventController controller => controller -> IO Text
controllerName controller =
  withManagedPtr controller
    $ \ptr -> pure ("gi-gtk-declarative-" <> Text.pack (show ptr))

-- | Disconnect a controller's handler and take the controller off the
-- widget again. The controller is looked up on the widget rather than
-- held onto, because the reference handed to 'Gtk.widgetAddController'
-- is not ours to use afterwards.
removeController :: Gtk.Widget -> Text -> Signals.SignalHandlerId -> IO ()
removeController widget' name handlerId = do
  controllers <- Gtk.widgetObserveControllers widget'
  count       <- Gio.listModelGetNItems controllers
  items       <- if count == 0
    then pure []
    else forM [0 .. count - 1] (Gio.listModelGetItem controllers)
  mapM_ removeIfNamed items
 where
  removeIfNamed Nothing    = pure ()
  removeIfNamed (Just obj) = do
    controller <- Gtk.unsafeCastTo Gtk.EventController obj
    this       <- Gtk.eventControllerGetName controller
    when (this == Just name) $ do
      GI.signalHandlerDisconnect controller handlerId
      Gtk.widgetRemoveController widget' controller

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
            (Just "gi-gtk-declarative")
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
