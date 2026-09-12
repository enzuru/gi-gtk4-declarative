{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedLabels      #-}

-- | Implementation of 'Gtk.CenterBox' as a declarative container.
module GI.Gtk.Declarative.Container.CenterBox
  ( CenterBoxChildren(..)
  , centerBox
  )
where

import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Container
import           GI.Gtk.Declarative.Container.Class
import           GI.Gtk.Declarative.Widget

-- | The three child widgets of a 'Gtk.CenterBox', in the order start,
-- center, end.
data CenterBoxChildren child = CenterBoxChildren child child child
  deriving (Functor)

-- | Construct a 'Gtk.CenterBox' from attributes and its start, center,
-- and end child widgets.
centerBox
  :: Vector (Attribute Gtk.CenterBox event)
  -> Widget event
  -> Widget event
  -> Widget event
  -> Widget event
centerBox attrs start center end =
  container Gtk.CenterBox attrs (CenterBoxChildren start center end)

instance ToChildren Gtk.CenterBox CenterBoxChildren Widget where
  toChildren _ (CenterBoxChildren s c e) = Children (Vector.fromList [s, c, e])

setSlot :: Gtk.CenterBox -> Int -> Maybe Gtk.Widget -> IO ()
setSlot box 0 widget' = Gtk.centerBoxSetStartWidget box widget'
setSlot box 1 widget' = Gtk.centerBoxSetCenterWidget box widget'
setSlot box _ widget' = Gtk.centerBoxSetEndWidget box widget'

instance IsContainer Gtk.CenterBox Widget where
  appendChild box _ widget' = do
    start  <- Gtk.centerBoxGetStartWidget box
    center <- Gtk.centerBoxGetCenterWidget box
    case (start, center) of
      (Nothing, _      ) -> setSlot box 0 (Just widget')
      (_      , Nothing) -> setSlot box 1 (Just widget')
      _                  -> setSlot box 2 (Just widget')
  replaceChild box _ i _old new = setSlot box (fromIntegral i) (Just new)
  removeChild box widget' = do
    start  <- Gtk.centerBoxGetStartWidget box
    center <- Gtk.centerBoxGetCenterWidget box
    let position | start == Just widget'  = 0
                 | center == Just widget' = 1
                 | otherwise              = 2
    setSlot box position (Nothing :: Maybe Gtk.Widget)
