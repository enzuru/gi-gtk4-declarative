-- The instances below are orphans, as everything in this package is:
-- the classes come from the core and the widgets from gi-adwaita.
{-# OPTIONS_GHC -Wno-orphans #-}

{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE RecordWildCards       #-}

-- | @AdwHeaderBar@ as a declarative container.
--
-- Widgets go at the start or at the end, as they do in a
-- 'GI.Gtk.HeaderBar':
--
-- @
-- container Adw.HeaderBar
--   [titleWidget (widget Adw.WindowTitle [#title := "Cellar"])]
--   [ headerBarStart (widget Gtk.Button [])
--   , headerBarEnd (widget Gtk.MenuButton [])
--   ]
-- @
--
-- The title is a property rather than a child, so it goes in the
-- 'GI.Gtk.Declarative.Adwaita.Slots.titleWidget' slot. A header bar
-- with no title widget shows the window's title, which is what
-- libadwaita does on its own.
--
-- The names here are the names "GI.Gtk.Declarative.Container.HeaderBar"
-- uses for the GTK header bar, so a module that uses both wants a
-- qualified import of one of them.
module GI.Gtk.Declarative.Adwaita.HeaderBar
  ( HeaderBarChild(..)
  , HeaderBarPosition(..)
  , headerBarStart
  , headerBarEnd
  )
where

import           Data.Vector                    ( Vector )
import qualified GI.Adw                        as Adw

import           GI.Gtk.Declarative.Container.Class
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.Widget

-- | Which end of an @AdwHeaderBar@ a child widget is packed at.
data HeaderBarPosition
  = HeaderBarStart
  | HeaderBarEnd
  deriving (Eq, Show)

-- | A child widget of an @AdwHeaderBar@.
data HeaderBarChild event =
  HeaderBarChild
    { position :: HeaderBarPosition
    , child    :: Widget event
    }
  deriving (Functor)

-- | A child widget packed at the start of the header bar.
headerBarStart :: Widget event -> HeaderBarChild event
headerBarStart = HeaderBarChild HeaderBarStart

-- | A child widget packed at the end of the header bar.
headerBarEnd :: Widget event -> HeaderBarChild event
headerBarEnd = HeaderBarChild HeaderBarEnd

instance Patchable HeaderBarChild where
  create = create . child
  patch s c1 c2 | position c1 == position c2 = patch s (child c1) (child c2)
                | otherwise                  = Replace (create c2)

instance EventSource HeaderBarChild where
  subscribe HeaderBarChild {..} = subscribe child

instance ToChildren Adw.HeaderBar Vector HeaderBarChild

instance IsContainer Adw.HeaderBar HeaderBarChild where
  appendChild bar HeaderBarChild { position } widget' = case position of
    HeaderBarStart -> Adw.headerBarPackStart bar widget'
    HeaderBarEnd   -> Adw.headerBarPackEnd bar widget'
  -- A packed child has no addressable position, so a child that is
  -- replaced rather than patched is packed back at the end of its own
  -- side.
  replaceChild bar headerBarChild' _index old new = do
    removeChild bar old
    appendChild bar headerBarChild' new
  removeChild = Adw.headerBarRemove
