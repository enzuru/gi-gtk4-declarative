{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE RecordWildCards       #-}

-- | Implementation of 'Gtk.ActionBar' as a declarative container.
module GI.Gtk.Declarative.Container.ActionBar
  ( ActionBarChild(..)
  , ActionBarPosition(..)
  , actionBarStart
  , actionBarEnd
  , actionBarCenter
  )
where

import           Data.Vector                    ( Vector )
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Container.Class
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.Widget

-- | Where in a 'Gtk.ActionBar' a child widget goes.
data ActionBarPosition
  = ActionBarStart
  | ActionBarEnd
  | ActionBarCenter
  deriving (Eq, Show)

-- | Describes a child widget to be added to a 'Gtk.ActionBar'.
data ActionBarChild event =
  ActionBarChild
    { position :: ActionBarPosition
    , child    :: Widget event
    }
  deriving (Functor)

-- | A child widget packed at the start of a 'Gtk.ActionBar'.
actionBarStart :: Widget event -> ActionBarChild event
actionBarStart = ActionBarChild ActionBarStart

-- | A child widget packed at the end of a 'Gtk.ActionBar'.
actionBarEnd :: Widget event -> ActionBarChild event
actionBarEnd = ActionBarChild ActionBarEnd

-- | The center widget of a 'Gtk.ActionBar'.
actionBarCenter :: Widget event -> ActionBarChild event
actionBarCenter = ActionBarChild ActionBarCenter

instance Patchable ActionBarChild where
  create = create . child
  patch s c1 c2 | position c1 == position c2 = patch s (child c1) (child c2)
                | otherwise                  = Replace (create c2)

instance EventSource ActionBarChild where
  subscribe ActionBarChild {..} = subscribe child

instance ToChildren Gtk.ActionBar Vector ActionBarChild

instance IsContainer Gtk.ActionBar ActionBarChild where
  appendChild bar ActionBarChild { position } widget' = case position of
    ActionBarStart  -> Gtk.actionBarPackStart bar widget'
    ActionBarEnd    -> Gtk.actionBarPackEnd bar widget'
    ActionBarCenter -> Gtk.actionBarSetCenterWidget bar (Just widget')
  replaceChild bar actionBarChild' _i old new = do
    removeChild bar old
    appendChild bar actionBarChild' new
  removeChild = Gtk.actionBarRemove
