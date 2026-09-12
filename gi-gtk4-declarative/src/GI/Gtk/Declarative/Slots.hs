-- Every helper below says both `Gtk.IsWindow widget` and
-- `Gtk.IsWidget widget`, which GHC would rather saw spelled out as
-- descendant constraints.
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widget-valued properties.
--
-- Some GTK widgets hold another widget in a property rather than as a
-- child: a window's title bar, a frame's label, the placeholder a list
-- box shows when it is empty. These cannot be written as an ordinary
-- attribute, because an attribute carries a value and what goes here is
-- a widget of your own, with its own attributes, children, and events.
--
-- Each function here is such a /slot/: an attribute holding a
-- declarative widget.
--
-- @
-- bin Window
--   [ #title := "Example"
--   , titlebar (container HeaderBar [] [headerBarTitle (widget Label [])])
--   ]
--   (widget Label [#label := "Nothing here yet."])
-- @
--
-- The widget in a slot is created, patched, and subscribed to like any
-- other, so it can carry event handlers and children of its own.
--
-- For a widget-valued property this module does not name, use 'slot'
-- from "GI.Gtk.Declarative.Attributes", giving it a name of its own and
-- the setter from gi-gtk.
module GI.Gtk.Declarative.Slots
  ( titlebar
  , frameLabel
  , expanderLabel
  , listBoxPlaceholder
  , menuButtonPopover
  )
where

import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Widget

-- | The title bar of a window, set with @gtk_window_set_titlebar@. This
-- is what puts a 'Gtk.HeaderBar' where the window manager's own title
-- bar would be.
titlebar
  :: (Gtk.IsWindow widget, Gtk.IsWidget widget)
  => Widget event
  -> Attribute widget event
titlebar = slot "titlebar" Gtk.windowSetTitlebar

-- | The label of a frame, in place of its text label.
frameLabel
  :: (Gtk.IsFrame widget, Gtk.IsWidget widget)
  => Widget event
  -> Attribute widget event
frameLabel = slot "label-widget" Gtk.frameSetLabelWidget

-- | The label of an expander, in place of its text label.
expanderLabel
  :: (Gtk.IsExpander widget, Gtk.IsWidget widget)
  => Widget event
  -> Attribute widget event
expanderLabel = slot "label-widget" Gtk.expanderSetLabelWidget

-- | What a list box shows while it has no rows.
listBoxPlaceholder
  :: (Gtk.IsListBox widget, Gtk.IsWidget widget)
  => Widget event
  -> Attribute widget event
listBoxPlaceholder = slot "placeholder" Gtk.listBoxSetPlaceholder

-- | The popover a menu button pops up. The widget must be a
-- 'Gtk.Popover', which is checked when the button is rendered.
menuButtonPopover
  :: (Gtk.IsMenuButton widget, Gtk.IsWidget widget)
  => Widget event
  -> Attribute widget event
menuButtonPopover = slot "popover" $ \widget' child -> do
  popover <- traverse (Gtk.unsafeCastTo Gtk.Popover) child
  Gtk.menuButtonSetPopover widget' popover
