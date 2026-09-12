{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE RecordWildCards       #-}

-- | Implementation of 'Gtk.HeaderBar' as a declarative container.
module GI.Gtk.Declarative.Container.HeaderBar
  ( HeaderBarChild(..)
  , HeaderBarPosition(..)
  , headerBarStart
  , headerBarEnd
  , headerBarTitle
  )
where

import           Data.Vector                    ( Vector )
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Container.Class
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.Widget

-- | Where in a 'Gtk.HeaderBar' a child widget goes.
data HeaderBarPosition
  = HeaderBarStart
  | HeaderBarEnd
  | HeaderBarTitle
  deriving (Eq, Show)

-- | Describes a child widget to be added to a 'Gtk.HeaderBar'.
data HeaderBarChild event =
  HeaderBarChild
    { position :: HeaderBarPosition
    , child    :: Widget event
    }
  deriving (Functor)

-- | A child widget packed at the start of a 'Gtk.HeaderBar'.
headerBarStart :: Widget event -> HeaderBarChild event
headerBarStart = HeaderBarChild HeaderBarStart

-- | A child widget packed at the end of a 'Gtk.HeaderBar'.
headerBarEnd :: Widget event -> HeaderBarChild event
headerBarEnd = HeaderBarChild HeaderBarEnd

-- | The title widget of a 'Gtk.HeaderBar'.
headerBarTitle :: Widget event -> HeaderBarChild event
headerBarTitle = HeaderBarChild HeaderBarTitle

instance Patchable HeaderBarChild where
  create = create . child
  patch s c1 c2 | position c1 == position c2 = patch s (child c1) (child c2)
                | otherwise                  = Replace (create c2)

instance EventSource HeaderBarChild where
  subscribe HeaderBarChild {..} = subscribe child

instance ToChildren Gtk.HeaderBar Vector HeaderBarChild

instance IsContainer Gtk.HeaderBar HeaderBarChild where
  appendChild bar HeaderBarChild { position } widget' = case position of
    HeaderBarStart -> Gtk.headerBarPackStart bar widget'
    HeaderBarEnd   -> Gtk.headerBarPackEnd bar widget'
    HeaderBarTitle -> Gtk.headerBarSetTitleWidget bar (Just widget')
  -- Packed children have no addressable position, so a replaced child
  -- is packed back at the end of its own side.
  replaceChild bar headerBarChild' _i old new = do
    removeChild bar old
    appendChild bar headerBarChild' new
  removeChild = Gtk.headerBarRemove
