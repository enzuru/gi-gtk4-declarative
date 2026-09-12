{-# OPTIONS_GHC -fno-warn-orphans #-}

{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Implementation of 'Gtk.FlowBox' as a declarative container.
module GI.Gtk.Declarative.Container.FlowBox where

import           Data.Vector                    ( Vector )
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Bin
import           GI.Gtk.Declarative.Container.Class

instance IsContainer Gtk.FlowBox (Bin Gtk.FlowBoxChild) where
  appendChild box _ widget' = Gtk.flowBoxInsert box widget' (-1)
  replaceChild box _ i old new = do
    Gtk.flowBoxRemove box old
    Gtk.flowBoxInsert box new i
  removeChild = Gtk.flowBoxRemove

instance ToChildren Gtk.FlowBox Vector (Bin Gtk.FlowBoxChild)
