{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE RecordWildCards         #-}
{-# LANGUAGE ScopedTypeVariables     #-}
{-# LANGUAGE OverloadedLabels       #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE TypeOperators          #-}

-- | Attribute lists on declarative objects, supporting the underlying
-- attributes from "Data.GI.Base.Attributes", along with CSS class lists, and
-- pure and impure event EventHandlers.

module GI.Gtk.Declarative.Attributes
  ( Attribute(..)
  , classes
  , ClassSet
  -- * After creation
  , afterCreated
  -- * Widget-valued properties
  , SlotSetter
  , slot
  , reference
  -- * Collecting attributes
  , collectAttributes
  , collectSlots
  -- * Event Handling
  , on
  , onM
  -- * Event Controllers
  , onController
  , onControllerM
  -- * EventHandlers
  , EventHandler(..)
  )
where

import qualified Data.GI.Base.Attributes       as GI
import qualified Data.GI.Base.Signals          as GI
import           Data.HashMap.Strict            ( HashMap )
import qualified Data.HashMap.Strict           as HashMap
import qualified Data.HashSet                  as HashSet
import qualified Data.Text                     as T
import           Data.Text                      ( Text )
import           Data.Typeable
import           Data.Vector                    ( Vector )
import           GHC.TypeLits                   ( KnownSymbol
                                                , Symbol
                                                , symbolVal
                                                )
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes.Collected
import           GI.Gtk.Declarative.Attributes.Internal.EventHandler
import           GI.Gtk.Declarative.Attributes.Internal.Conversions
import           GI.Gtk.Declarative.Widget

-- * Attributes

-- | The attribute GADT represent a supported attribute for a declarative
-- widget. This extends the regular notion of GTK+ attributes to also include
-- event handling and CSS classes.
data Attribute widget event where
  -- | An attribute/value mapping for a declarative widget. The
  -- 'GI.AttrLabelProxy' is parameterized by 'attr', which represents the
  -- GTK-defined attribute name. The underlying GI object needs to support
  -- the /construct/, /get/, and /set/ operations for the given attribute.
  (:=)
    ::(GI.AttrOpAllowed 'GI.AttrConstruct info widget
      , GI.AttrOpAllowed 'GI.AttrSet info widget
      , GI.AttrGetC info widget attr getValue
      , GI.AttrSetTypeConstraint info setValue
      , KnownSymbol attr
      , Typeable attr
      , Eq setValue
      , Typeable setValue
      )
   => GI.AttrLabelProxy (attr :: Symbol) -> setValue -> Attribute widget event
  -- | Defines a set of CSS classes for the underlying widget's style context.
  -- Use the 'classes' function instead of this constructor directly.
  Classes
    ::Gtk.IsWidget widget
    => ClassSet
    -> Attribute widget event
  -- | Emit events using a pure event handler. Use the 'on' function, instead of this
  -- constructor directly.
  OnSignalPure
    ::( Gtk.GObject widget
       , GI.SignalInfo info
       , gtkCallback ~ GI.HaskellCallbackType info
       , ToGtkCallback gtkCallback Pure
       )
    => Gtk.SignalProxy widget info
    -> EventHandler gtkCallback widget Pure event
    -> Attribute widget event
  -- | Emit events using a pure event handler. Use the 'on' function, instead of this
  -- constructor directly.
  OnSignalImpure
    ::( Gtk.GObject widget
       , GI.SignalInfo info
       , gtkCallback ~ GI.HaskellCallbackType info
       , ToGtkCallback gtkCallback Impure
       )
    => Gtk.SignalProxy widget info
    -> EventHandler gtkCallback widget Impure event
    -> Attribute widget event
  -- | Run an action on the widget, once, when it has been built. Use
  -- the 'afterCreated' function, instead of this constructor directly.
  AfterCreated
    ::(widget -> IO ())
    -> Attribute widget event
  -- | Put a declarative widget in one of this widget's widget-valued
  -- properties, such as a window's title bar. Use the functions in
  -- "GI.Gtk.Declarative.Slots", or 'slot', instead of this constructor
  -- directly.
  Slot
    ::Gtk.IsWidget widget
    => Text
    -> SlotSetter widget
    -> Widget event
    -> Attribute widget event
  -- | Point one of this widget's widget-valued properties at another
  -- widget, named by its @name@ property. Use the functions in
  -- "GI.Gtk.Declarative.References", or 'reference', instead of this
  -- constructor directly.
  Reference
    ::Gtk.IsWidget widget
    => SlotSetter widget
    -> Text
    -> Attribute widget event
  -- | Add an event controller to the widget, and emit events from one
  -- of the controller's signals. GTK 4 handles keys, pointers, and
  -- gestures through controllers rather than through signals on the
  -- widget itself. Use the 'onController' and 'onControllerM'
  -- functions, instead of this constructor directly.
  OnControllerPure
    ::( Gtk.IsWidget widget
       , Gtk.IsEventController controller
       , GI.SignalInfo info
       , gtkCallback ~ GI.HaskellCallbackType info
       , ToGtkCallback gtkCallback Pure
       )
    => IO controller
    -> Gtk.SignalProxy controller info
    -> EventHandler gtkCallback widget Pure event
    -> Attribute widget event
  -- | As 'OnControllerPure', with an impure event handler. Use the
  -- 'onControllerM' function, instead of this constructor directly.
  OnControllerImpure
    ::( Gtk.IsWidget widget
       , Gtk.IsEventController controller
       , GI.SignalInfo info
       , gtkCallback ~ GI.HaskellCallbackType info
       , ToGtkCallback gtkCallback Impure
       )
    => IO controller
    -> Gtk.SignalProxy controller info
    -> EventHandler gtkCallback widget Impure event
    -> Attribute widget event

-- | Attributes have a 'Functor' instance that maps events in all
-- event handler.
instance Functor (Attribute widget) where
  fmap f = \case
    attr := value            -> attr := value
    Classes cs               -> Classes cs
    OnSignalPure   signal eh -> OnSignalPure signal (fmap f eh)
    OnSignalImpure signal eh -> OnSignalImpure signal (fmap f eh)
    AfterCreated action      -> AfterCreated action
    Slot name setter child   -> Slot name setter (fmap f child)
    Reference setter name    -> Reference setter name
    OnControllerPure new signal eh -> OnControllerPure new signal (fmap f eh)
    OnControllerImpure new signal eh ->
      OnControllerImpure new signal (fmap f eh)

-- | Define the CSS classes for the underlying widget's style context. For these
-- classes to have any effect, this requires a 'Gtk.CssProvider' with CSS files
-- loaded, to be added to the GDK screen. You probably want to do this in your
-- entry point when setting up GTK.
classes :: Gtk.IsWidget widget => [T.Text] -> Attribute widget event
classes = Classes . HashSet.fromList

-- | Emit events, using a pure event handler, by subcribing to the specified
-- signal.
on
  :: ( Gtk.GObject widget
     , GI.SignalInfo info
     , gtkCallback ~ GI.HaskellCallbackType info
     , ToGtkCallback gtkCallback Pure
     , ToEventHandler gtkCallback widget Pure
     , userEventHandler ~ UserEventHandler gtkCallback widget Pure event
     )
  => Gtk.SignalProxy widget info
  -> userEventHandler
  -> Attribute widget event
on signal = OnSignalPure signal . toEventHandler

-- | Emit events, using an impure event handler receiving the 'widget' and returning
-- an 'IO' action of 'event', by subcribing to the specified signal.
onM
  :: ( Gtk.GObject widget
     , GI.SignalInfo info
     , gtkCallback ~ GI.HaskellCallbackType info
     , ToGtkCallback gtkCallback Impure
     , ToEventHandler gtkCallback widget Impure
     , userEventHandler ~ UserEventHandler gtkCallback widget Impure event
     )
  => Gtk.SignalProxy widget info
  -> userEventHandler
  -> Attribute widget event
onM signal = OnSignalImpure signal . toEventHandler

-- | Emit events from an event controller added to the widget, using a
-- pure event handler.
--
-- GTK 4 moved keys, pointers, and gestures out of the widget's own
-- signals and into event controllers, so this is how a declarative
-- widget reacts to a key press or a click:
--
-- @
-- widget Gtk.Label
--   [ onController Gtk.gestureClickNew #pressed
--       (\\_nPress x y -> Clicked x y)
--   ]
-- @
--
-- The controller is added when the widget is first subscribed to, and
-- stays on the widget until the attributes stop asking for it.
-- Cancelling a subscription disconnects the handler behind it and
-- leaves the controller where it is, so that a gesture keeps what it
-- has counted across a patch. The library names the controller to find
-- it again, so a name set on the controller beforehand does not
-- survive.
--
-- "GI.Gtk.Declarative.EventController" has ready-made versions of this
-- for the common controllers.
onController
  :: ( Gtk.IsWidget widget
     , Gtk.IsEventController controller
     , GI.SignalInfo info
     , gtkCallback ~ GI.HaskellCallbackType info
     , ToGtkCallback gtkCallback Pure
     , ToEventHandler gtkCallback widget Pure
     , userEventHandler ~ UserEventHandler gtkCallback widget Pure event
     )
  => IO controller                      -- ^ Creates the event controller.
  -> Gtk.SignalProxy controller info    -- ^ A signal of that controller.
  -> userEventHandler
  -> Attribute widget event
onController newController signal =
  OnControllerPure newController signal . toEventHandler

-- | Emit events from an event controller added to the widget, using an
-- impure event handler. The handler receives the widget and returns an
-- IO action of the event, as 'onM' does.
onControllerM
  :: ( Gtk.IsWidget widget
     , Gtk.IsEventController controller
     , GI.SignalInfo info
     , gtkCallback ~ GI.HaskellCallbackType info
     , ToGtkCallback gtkCallback Impure
     , ToEventHandler gtkCallback widget Impure
     , userEventHandler ~ UserEventHandler gtkCallback widget Impure event
     )
  => IO controller                      -- ^ Creates the event controller.
  -> Gtk.SignalProxy controller info    -- ^ A signal of that controller.
  -> userEventHandler
  -> Attribute widget event
onControllerM newController signal =
  OnControllerImpure newController signal . toEventHandler

-- | How a widget-valued property is set. 'Nothing' unsets it.
type SlotSetter widget = widget -> Maybe Gtk.Widget -> IO ()

-- | Put a declarative widget in a widget-valued property of another
-- widget, such as a window's title bar.
--
-- The name tells one slot from another when patching, so a widget's
-- two slots must not share a name. "GI.Gtk.Declarative.Slots" has this
-- ready-made for the widgets that have such a property.
slot
  :: Gtk.IsWidget widget
  => Text                -- ^ A name for the slot, unique to this widget.
  -> SlotSetter widget   -- ^ Sets the property.
  -> Widget event        -- ^ The widget to put there.
  -> Attribute widget event
slot = Slot

-- | Run an action on the underlying GTK widget, once, when it has been
-- built and its children are in place.
--
-- This is the way out of the declarative model, for the things GTK
-- gives no other way to reach: adding a style provider to the display,
-- taking the keyboard focus, or putting a gesture on a widget the
-- library does not hand you.
--
-- @
-- widget Gtk.Label [afterCreated (\label -> Gtk.widgetGrabFocus label)]
-- @
--
-- It runs at creation and never again. A patch does not run it, so
-- whatever it does has to be something that survives the widget being
-- patched, or something the action itself keeps an eye on.
afterCreated :: (widget -> IO ()) -> Attribute widget event
afterCreated = AfterCreated

-- | Point a widget-valued property at another widget somewhere else in
-- the tree, named by its @name@ property.
--
-- Some widgets do not hold the widget they work on: a
-- 'Gtk.StackSwitcher' switches a 'Gtk.Stack' that lives wherever the
-- layout puts it, which is usually not next to the switcher. Name the
-- one and point at it from the other:
--
-- @
-- container Gtk.HeaderBar []
--   [ headerBarTitle (widget Gtk.StackSwitcher [switcherStack "pages"]) ]
-- ...
-- container Gtk.Stack [#name := "pages"] children
-- @
--
-- The reference is resolved on the next turn of the main loop, once
-- when the whole tree is built and again after each patch, by looking
-- through the widgets under the same root for one with that name. It
-- waits because a widget that names another is often built before it.
-- A caller that reads the property straight after building the tree
-- therefore reads it before it is set; a running application never
-- notices. A name that matches nothing is reported as a warning
-- through GLib.
--
-- "GI.Gtk.Declarative.References" has this ready-made for the widgets
-- that point at another widget.
reference
  :: Gtk.IsWidget widget
  => SlotSetter widget  -- ^ Sets the property.
  -> Text               -- ^ The @name@ of the widget to point at.
  -> Attribute widget event
reference = Reference

-- | Collect declarative markup attributes to the patching-optimized
-- 'Collected' data structure.
collectAttributes :: Vector (Attribute widget event) -> Collected widget event
collectAttributes = foldl' go mempty
 where
  go
    :: Collected widget event
    -> Attribute widget event
    -> Collected widget event
  go Collected {..} = \case
    attr := value -> Collected
      { collectedProperties = HashMap.insert (T.pack (symbolVal attr))
                                             (CollectedProperty attr value)
                                             collectedProperties
      , ..
      }
    Classes classSet ->
      Collected { collectedClasses = collectedClasses <> classSet, .. }
    _ -> Collected { .. }

-- | The widget-valued properties of an attribute list, by slot name.
collectSlots
  :: forall widget event
   . Vector (Attribute widget event)
  -> HashMap Text (SlotSetter widget, Widget event)
collectSlots = foldl' go HashMap.empty
 where
  go
    :: HashMap Text (SlotSetter widget, Widget event)
    -> Attribute widget event
    -> HashMap Text (SlotSetter widget, Widget event)
  go slots = \case
    Slot name setter child -> HashMap.insert name (setter, child) slots
    _                      -> slots
