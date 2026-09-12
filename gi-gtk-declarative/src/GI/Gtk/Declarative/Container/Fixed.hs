{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE RecordWildCards       #-}

-- | Implementation of 'Gtk.Fixed' as a declarative container.
module GI.Gtk.Declarative.Container.Fixed
  ( FixedChild(..)
  , FixedChildProperties(..)
  , defaultFixedChildProperties
  )
where

import           Data.Default.Class             ( Default(def) )
import           Data.Vector                    ( Vector )
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Container.Class
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.Widget

-- | Describes a child widget to be placed in a 'Gtk.Fixed'.
data FixedChild event =
  FixedChild
    { properties :: FixedChildProperties
    , child      :: Widget event
    }
  deriving (Functor)

-- | The position, in pixels, of a child widget in a 'Gtk.Fixed'.
data FixedChildProperties =
  FixedChildProperties
    { x :: Double
    , y :: Double
    }
  deriving (Eq, Show)

-- | Defaults for 'FixedChildProperties'. Use these and override
-- specific fields.
defaultFixedChildProperties :: FixedChildProperties
defaultFixedChildProperties = FixedChildProperties { x = 0, y = 0 }

instance Default FixedChildProperties where
  def = defaultFixedChildProperties

instance Patchable FixedChild where
  create = create . child
  patch s c1 c2 | properties c1 == properties c2 = patch s (child c1) (child c2)
                | otherwise                      = Replace (create c2)

instance EventSource FixedChild where
  subscribe FixedChild {..} = subscribe child

instance ToChildren Gtk.Fixed Vector FixedChild

instance IsContainer Gtk.Fixed FixedChild where
  appendChild fixed FixedChild { properties } widget' = do
    let FixedChildProperties { x, y } = properties
    Gtk.fixedPut fixed widget' x y
  replaceChild fixed fixedChild' _i old new = do
    Gtk.fixedRemove fixed old
    appendChild fixed fixedChild' new
  removeChild = Gtk.fixedRemove
