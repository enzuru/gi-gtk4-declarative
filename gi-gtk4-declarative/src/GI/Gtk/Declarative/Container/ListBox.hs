{-# OPTIONS_GHC -fno-warn-orphans #-}

{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Implementation of 'Gtk.ListBox' as a declarative container.
--
-- A list box takes any widget as a child, which is what lets a row from
-- another library, such as an @AdwActionRow@, go in one. Writing the
-- row out with @bin Gtk.ListBoxRow@ still works, and is what you want
-- when the row itself needs attributes.
--
-- A child that is not a 'Gtk.ListBoxRow' is put in one here. GTK would
-- do that itself, but @gtk_list_box_remove@ is then unable to find the
-- wrapper again and says so: /Tried to remove non-child/. Wrapping the
-- child here keeps the wrapper reachable, through the child's parent.
module GI.Gtk.Declarative.Container.ListBox where

import           Data.Foldable                  ( for_ )
import           Data.Vector                    ( Vector )
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Container.Class
import           GI.Gtk.Declarative.Widget

instance IsContainer Gtk.ListBox Widget where
  appendChild box _ widget' = do
    row <- asRow widget'
    Gtk.listBoxInsert box row (-1)
  replaceChild box _declarative i old new = do
    removeChild box old
    row <- asRow new
    Gtk.listBoxInsert box row i
  removeChild box widget' = do
    row <- rowOf widget'
    for_ row (Gtk.listBoxRemove box)

instance ToChildren Gtk.ListBox Vector Widget

-- | The child itself when it is a row, and a row holding it when it is
-- not.
asRow :: Gtk.Widget -> IO Gtk.Widget
asRow widget' = do
  isRow <- Gtk.castTo Gtk.ListBoxRow widget'
  case isRow of
    Just _  -> pure widget'
    Nothing -> do
      row <- Gtk.new Gtk.ListBoxRow []
      Gtk.listBoxRowSetChild row (Just widget')
      Gtk.toWidget row

-- | The row a child sits in, which is the child itself when it is a
-- row, and its parent when this module wrapped it.
rowOf :: Gtk.Widget -> IO (Maybe Gtk.Widget)
rowOf widget' = do
  isRow <- Gtk.castTo Gtk.ListBoxRow widget'
  case isRow of
    Just _  -> pure (Just widget')
    Nothing -> Gtk.widgetGetParent widget'
