-- The instances below are orphans, as everything in this package is:
-- the classes come from the core and the widgets from gi-adwaita.
{-# OPTIONS_GHC -Wno-orphans #-}

{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE RecordWildCards       #-}

-- | @AdwToolbarView@ as a declarative container.
--
-- A toolbar view holds a content widget, any number of bars above it,
-- and any number below. Each child says where it goes:
--
-- @
-- container Adw.ToolbarView []
--   [ toolbarTop (container Adw.HeaderBar [] [])
--   , toolbarTop (widget Adw.TabBar [])
--   , toolbarContent theGrid
--   , toolbarBottom (container Gtk.ActionBar [] [])
--   ]
-- @
--
-- The bars appear in the order they are given, top to bottom at each
-- end.
--
-- A view with one bar at each end is a 'GI.Gtk.Declarative.Bin.bin'
-- instead, whose child is the content and whose bars are the two slots
-- in "GI.Gtk.Declarative.Adwaita.Slots". Both say the same thing; this
-- one is for a view with more than one bar at an end.
module GI.Gtk.Declarative.Adwaita.ToolbarView
  ( ToolbarChild(..)
  , ToolbarPosition(..)
  , toolbarTop
  , toolbarContent
  , toolbarBottom
  )
where

import           Control.Monad                  ( when )
import           Data.Vector                    ( Vector )
import qualified GI.Adw                        as Adw
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Container.Class
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.Widget

-- | Where in a toolbar view a child widget goes.
data ToolbarPosition
  = ToolbarTop
  | ToolbarContent
  | ToolbarBottom
  deriving (Eq, Show)

-- | A child widget of a toolbar view.
data ToolbarChild event =
  ToolbarChild
    { position :: ToolbarPosition
    , child    :: Widget event
    }
  deriving (Functor)

-- | A bar above the content.
toolbarTop :: Widget event -> ToolbarChild event
toolbarTop = ToolbarChild ToolbarTop

-- | The content, which is the widget the bars are around. A view has
-- one of these.
toolbarContent :: Widget event -> ToolbarChild event
toolbarContent = ToolbarChild ToolbarContent

-- | A bar below the content.
toolbarBottom :: Widget event -> ToolbarChild event
toolbarBottom = ToolbarChild ToolbarBottom

instance Patchable ToolbarChild where
  create = create . child
  patch s c1 c2 | position c1 == position c2 = patch s (child c1) (child c2)
                | otherwise                  = Replace (create c2)

instance EventSource ToolbarChild where
  subscribe ToolbarChild {..} = subscribe child

instance ToChildren Adw.ToolbarView Vector ToolbarChild

instance IsContainer Adw.ToolbarView ToolbarChild where
  appendChild view ToolbarChild { position } widget' = case position of
    ToolbarTop     -> Adw.toolbarViewAddTopBar view widget'
    ToolbarBottom  -> Adw.toolbarViewAddBottomBar view widget'
    ToolbarContent -> Adw.toolbarViewSetContent view (Just widget')
  -- A bar has no addressable position, so a bar that is replaced
  -- rather than patched is added back at the end of its own end.
  replaceChild view toolbarChild' _index old new = do
    removeChild view old
    appendChild view toolbarChild' new
  -- Setting the content unparents the content that was there, so a
  -- child can be gone before the time comes to take it out. Asking the
  -- view to remove a widget it no longer holds is a warning from
  -- libadwaita rather than an error, and one worth not causing.
  removeChild view widget' = do
    inside <- Gtk.widgetIsAncestor widget' view
    when inside (Adw.toolbarViewRemove view widget')
