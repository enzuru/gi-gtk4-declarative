{-# OPTIONS_GHC -fno-warn-orphans #-}

{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Implementation of 'Gtk.ListBox' as a declarative container.
module GI.Gtk.Declarative.Container.ListBox where

import           Data.Vector                    ( Vector )
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Bin
import           GI.Gtk.Declarative.Container.Class

instance IsContainer Gtk.ListBox (Bin Gtk.ListBoxRow) where
  appendChild box _ widget' = Gtk.listBoxInsert box widget' (-1)
  replaceChild box _ i old new = do
    Gtk.listBoxRemove box old
    Gtk.listBoxInsert box new i
  removeChild = Gtk.listBoxRemove

instance ToChildren Gtk.ListBox Vector (Bin Gtk.ListBoxRow)
