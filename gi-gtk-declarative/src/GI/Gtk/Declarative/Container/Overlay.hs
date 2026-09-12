{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Implementation of 'Gtk.Overlay' as a declarative container.
--
-- The first child is the main child of the overlay, and the ones after
-- it are drawn on top of it, in order.
module GI.Gtk.Declarative.Container.Overlay where

import           Data.Vector                    ( Vector )
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Container.Class
import           GI.Gtk.Declarative.Widget

instance ToChildren Gtk.Overlay Vector Widget

instance IsContainer Gtk.Overlay Widget where
  appendChild overlay _ widget' = do
    mainChild <- Gtk.overlayGetChild overlay
    case mainChild of
      Nothing -> Gtk.overlaySetChild overlay (Just widget')
      Just _  -> Gtk.overlayAddOverlay overlay widget'
  replaceChild overlay declarative i old new = do
    removeChild overlay old
    if i == 0
      then Gtk.overlaySetChild overlay (Just new)
      else appendChild overlay declarative new
  removeChild overlay widget' = do
    mainChild <- Gtk.overlayGetChild overlay
    if mainChild == Just widget'
      then Gtk.overlaySetChild overlay (Nothing :: Maybe Gtk.Widget)
      else Gtk.overlayRemoveOverlay overlay widget'
