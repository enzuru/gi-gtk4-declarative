-- The instances below are orphans, as everything in this package is:
-- the classes come from the core and the widgets from gi-adwaita.
{-# OPTIONS_GHC -Wno-orphans #-}

{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE RecordWildCards       #-}

-- 'headerSuffix' names a specific Adwaita class and `Gtk.IsWidget`
-- both, which GHC would rather saw spelled out as descendant
-- constraints.
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

-- | The rows a libadwaita settings page is made of.
--
-- A page is an @AdwPreferencesGroup@ holding rows:
--
-- @
-- container Adw.PreferencesGroup
--   [#title := "Board", headerSuffix (widget Gtk.Button [])]
--   [ widget Adw.SwitchRow [#title := "Show coordinates", #active := showing]
--   , container Adw.ActionRow
--               [#title := "Size"]
--               [rowSuffix (toggleGroup [] sizes)]
--   ]
-- @
--
-- A row with one value and no children is a widget like any other:
-- @AdwSwitchRow@, @AdwSpinRow@, @AdwEntryRow@ and @AdwPasswordEntryRow@
-- need nothing from this module, because what they hold is properties.
-- A list box takes them as they are, and so does a preferences group.
--
-- An @AdwActionRow@ is the one that holds widgets, at either end of
-- itself, so it is a container.
module GI.Gtk.Declarative.Adwaita.Rows
  ( ActionRowChild(..)
  , ActionRowPosition(..)
  , rowPrefix
  , rowSuffix
  , headerSuffix
  )
where

import           Data.Vector                    ( Vector )
import qualified GI.Adw                        as Adw
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Container.Class
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.Widget

--
-- The preferences group
--

-- | A group of rows, with a title and a description of its own.
instance ToChildren Adw.PreferencesGroup Vector Widget

instance IsContainer Adw.PreferencesGroup Widget where
  appendChild group _ widget' = Adw.preferencesGroupAdd group widget'
  -- A group has no way of putting a row at a position, so a row that
  -- is replaced rather than patched goes back at the end.
  replaceChild group child' _index old new = do
    removeChild group old
    appendChild group child' new
  removeChild = Adw.preferencesGroupRemove

-- | The widget beside a preferences group's title, which is usually a
-- button that acts on the whole group.
headerSuffix
  :: (Adw.IsPreferencesGroup widget, Gtk.IsWidget widget)
  => Widget event
  -> Attribute widget event
headerSuffix = slot "header-suffix" Adw.preferencesGroupSetHeaderSuffix

--
-- The page a group goes on, and the dialog a page goes in
--

-- | A page of preferences groups.
--
-- A page takes groups and nothing else. A child that is not one fails
-- the cast here, rather than becoming a warning from libadwaita when
-- the page is shown.
instance ToChildren Adw.PreferencesPage Vector Widget

instance IsContainer Adw.PreferencesPage Widget where
  appendChild page _ widget' =
    Adw.preferencesPageAdd page =<< asGroup widget'
  replaceChild page child' _index old new = do
    removeChild page old
    appendChild page child' new
  removeChild page widget' = Adw.preferencesPageRemove page =<< asGroup widget'

asGroup :: Gtk.Widget -> IO Adw.PreferencesGroup
asGroup = Gtk.unsafeCastTo Adw.PreferencesGroup

-- | A dialog of preferences pages, which takes pages and nothing else.
instance ToChildren Adw.PreferencesDialog Vector Widget

instance IsContainer Adw.PreferencesDialog Widget where
  appendChild dialog _ widget' =
    Adw.preferencesDialogAdd dialog =<< asPage widget'
  replaceChild dialog child' _index old new = do
    removeChild dialog old
    appendChild dialog child' new
  removeChild dialog widget' =
    Adw.preferencesDialogRemove dialog =<< asPage widget'

asPage :: Gtk.Widget -> IO Adw.PreferencesPage
asPage = Gtk.unsafeCastTo Adw.PreferencesPage

--
-- The expander row
--

-- | A row that reveals rows of its own.
--
-- The switch in its header is @#enableExpansion@, which is a property
-- a person changes and a program owns, so it wants
-- 'GI.Gtk.Declarative.Attributes.holding':
--
-- @
-- container Adw.ExpanderRow
--   [#title := "Nightlies", #showEnableSwitch := True
--   , holding #enableExpansion (nightlies state)
--   ]
--   [widget Adw.EntryRow [#title := "Metadata URL"]]
-- @
instance ToChildren Adw.ExpanderRow Vector Widget

instance IsContainer Adw.ExpanderRow Widget where
  appendChild row _ widget' = Adw.expanderRowAddRow row widget'
  replaceChild row child' _index old new = do
    removeChild row old
    appendChild row child' new
  removeChild = Adw.expanderRowRemove

--
-- The action row
--

-- | Which end of an @AdwActionRow@ a child widget is at.
data ActionRowPosition
  = ActionRowPrefix
  | ActionRowSuffix
  deriving (Eq, Show)

-- | A child widget of an @AdwActionRow@.
data ActionRowChild event =
  ActionRowChild
    { position :: ActionRowPosition
    , child    :: Widget event
    }
  deriving (Functor)

-- | A child widget at the start of the row, before its title.
rowPrefix :: Widget event -> ActionRowChild event
rowPrefix = ActionRowChild ActionRowPrefix

-- | A child widget at the end of the row, after its title. This is
-- where the thing the row is about goes.
rowSuffix :: Widget event -> ActionRowChild event
rowSuffix = ActionRowChild ActionRowSuffix

instance Patchable ActionRowChild where
  create = create . child
  patch s c1 c2 | position c1 == position c2 = patch s (child c1) (child c2)
                | otherwise                  = Replace (create c2)

instance EventSource ActionRowChild where
  subscribe ActionRowChild {..} = subscribe child

instance ToChildren Adw.ActionRow Vector ActionRowChild

instance IsContainer Adw.ActionRow ActionRowChild where
  appendChild row ActionRowChild { position } widget' = case position of
    ActionRowPrefix -> Adw.actionRowAddPrefix row widget'
    ActionRowSuffix -> Adw.actionRowAddSuffix row widget'
  -- A child at one end has no addressable position among the others,
  -- so one that is replaced goes back at the end of its own end.
  replaceChild row actionRowChild' _index old new = do
    removeChild row old
    appendChild row actionRowChild' new
  removeChild = Adw.actionRowRemove
