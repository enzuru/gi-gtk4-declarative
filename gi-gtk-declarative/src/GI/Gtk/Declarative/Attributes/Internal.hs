{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Internal helpers for applying attributes and signal handlers to GTK
-- widgets.
module GI.Gtk.Declarative.Attributes.Internal
  ( addSignalHandler
  )
where

import           Control.Monad                  ( forM
                                                , when
                                                )
import           Control.Monad.IO.Class         ( MonadIO
                                                , liftIO
                                                )
import           Data.GI.Base                   ( withManagedPtr )
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import qualified Data.GI.Base.Signals          as Signals
import qualified GI.GObject                    as GI
import qualified GI.Gio                        as Gio
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Attributes.Internal.Conversions
import           GI.Gtk.Declarative.EventSource

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
