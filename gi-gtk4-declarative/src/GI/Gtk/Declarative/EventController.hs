-- Every helper below says `Gtk.IsWidget widget`, which is the
-- constraint a gi-gtk user writes. GHC would rather it were spelled out
-- as a descendant constraint, which would say the same thing less
-- clearly.
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Declarative event controllers.
--
-- GTK 4 took keys, pointers, and gestures out of the widget's own
-- signals and put them in event controllers, which are objects you add
-- to a widget. The GTK 3 signals for this, such as @key-press-event@
-- and @button-press-event@, are gone.
--
-- These are the common controllers, each as an attribute you can put in
-- a widget's attribute list:
--
-- @
-- widget Gtk.Label
--   [ #label := "Click me"
--   , onClickPressed (\\_nPress x y -> Clicked x y)
--   ]
-- @
--
-- The controller is added when the widget is first subscribed to, and
-- stays on the widget for as long as the attribute asks for it. What
-- the subscription owns is the handler behind it, which goes when the
-- subscription is cancelled.
--
-- The controller outlives a patch on purpose. A gesture counts what it
-- has seen: a 'Gtk.GestureClick' knows that the click it is reporting
-- is the second of a double click. An application patches and
-- subscribes again on every event, so a gesture that came off with its
-- subscription would count from none after every event, and the second
-- click of a double click would arrive as a first.
--
-- For a controller this module does not name, and for handlers that
-- need the widget, use 'onController' and 'onControllerM' from
-- "GI.Gtk.Declarative.Attributes".
module GI.Gtk.Declarative.EventController
  ( -- * Keys
    onKeyPressed
  , onKeyReleased
    -- * Clicks
  , onClickPressed
  , onClickReleased
    -- * Pointer
  , onMotion
  , onPointerEnter
  , onPointerLeave
    -- * Focus
  , onFocusEnter
  , onFocusLeave
    -- * Scrolling
  , onScrolled
    -- * Dragging
  , onDragBegin
  , onDragUpdate
  , onDragEnd
    -- * Long presses
  , onLongPressed
  )
where

import           Data.Int                       ( Int32 )
import           Data.Word                      ( Word32 )
import qualified GI.Gdk                        as Gdk
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes

-- | A key was pressed while the widget had the keyboard focus. The
-- handler receives the key value, the hardware key code, and the
-- modifiers held down, and returns whether it dealt with the key. A
-- handler that returns 'True' stops the key going any further.
onKeyPressed
  :: Gtk.IsWidget widget
  => (Word32 -> Word32 -> [Gdk.ModifierType] -> (Bool, event))
  -> Attribute widget event
onKeyPressed = onController Gtk.eventControllerKeyNew #keyPressed

-- | A key was released. The arguments are those of 'onKeyPressed'.
onKeyReleased
  :: Gtk.IsWidget widget
  => (Word32 -> Word32 -> [Gdk.ModifierType] -> event)
  -> Attribute widget event
onKeyReleased = onController Gtk.eventControllerKeyNew #keyReleased

-- | A mouse button went down on the widget. The handler receives the
-- number of presses in this sequence, which is 2 for a double click,
-- and the position of the pointer in the widget.
onClickPressed
  :: Gtk.IsWidget widget
  => (Int32 -> Double -> Double -> event)
  -> Attribute widget event
onClickPressed = onController Gtk.gestureClickNew #pressed

-- | A mouse button came back up. The arguments are those of
-- 'onClickPressed'.
onClickReleased
  :: Gtk.IsWidget widget
  => (Int32 -> Double -> Double -> event)
  -> Attribute widget event
onClickReleased = onController Gtk.gestureClickNew #released

-- | The pointer moved over the widget. The handler receives its
-- position in the widget.
onMotion
  :: Gtk.IsWidget widget
  => (Double -> Double -> event)
  -> Attribute widget event
onMotion = onController Gtk.eventControllerMotionNew #motion

-- | The pointer came into the widget, at this position.
onPointerEnter
  :: Gtk.IsWidget widget
  => (Double -> Double -> event)
  -> Attribute widget event
onPointerEnter = onController Gtk.eventControllerMotionNew #enter

-- | The pointer left the widget.
onPointerLeave :: Gtk.IsWidget widget => event -> Attribute widget event
onPointerLeave = onController Gtk.eventControllerMotionNew #leave

-- | The widget, or something inside it, took the keyboard focus.
onFocusEnter :: Gtk.IsWidget widget => event -> Attribute widget event
onFocusEnter = onController Gtk.eventControllerFocusNew #enter

-- | The widget, or something inside it, lost the keyboard focus.
onFocusLeave :: Gtk.IsWidget widget => event -> Attribute widget event
onFocusLeave = onController Gtk.eventControllerFocusNew #leave

-- | The widget was scrolled over. The handler receives the distance
-- scrolled on each axis, and returns whether it dealt with the scroll.
-- The flags say which axes to report, and whether to emit kinetic
-- scrolling.
onScrolled
  :: Gtk.IsWidget widget
  => [Gtk.EventControllerScrollFlags]
  -> (Double -> Double -> (Bool, event))
  -> Attribute widget event
onScrolled flags =
  onController (Gtk.eventControllerScrollNew flags) #scroll

-- | A drag started on the widget, at this position.
onDragBegin
  :: Gtk.IsWidget widget
  => (Double -> Double -> event)
  -> Attribute widget event
onDragBegin = onController Gtk.gestureDragNew #dragBegin

-- | A drag moved. The handler receives how far it has come from where
-- it began, not where the pointer now is.
onDragUpdate
  :: Gtk.IsWidget widget
  => (Double -> Double -> event)
  -> Attribute widget event
onDragUpdate = onController Gtk.gestureDragNew #dragUpdate

-- | A drag finished. The arguments are those of 'onDragUpdate'.
onDragEnd
  :: Gtk.IsWidget widget
  => (Double -> Double -> event)
  -> Attribute widget event
onDragEnd = onController Gtk.gestureDragNew #dragEnd

-- | A mouse button was held down on the widget for long enough to
-- count as a long press, at this position.
onLongPressed
  :: Gtk.IsWidget widget
  => (Double -> Double -> event)
  -> Attribute widget event
onLongPressed = onController Gtk.gestureLongPressNew #pressed
