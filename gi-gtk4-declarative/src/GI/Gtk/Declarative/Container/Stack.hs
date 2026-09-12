{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedLabels      #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}

-- | Implementation of 'Gtk.Stack' as a declarative container.
module GI.Gtk.Declarative.Container.Stack
  ( StackChild(..)
  , StackChildProperties(..)
  , defaultStackChildProperties
  )
where

import           Data.Default.Class             ( Default(def) )
import           Data.Text                      ( Text )
import           Data.Vector                    ( Vector )
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Container.Class
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.Widget

-- | Describes a child widget to be added to a 'Gtk.Stack'.
data StackChild event =
  StackChild
    { properties :: StackChildProperties
    , child      :: Widget event
    }
  deriving (Functor)

-- | Values used when adding child widgets to stacks. The 'name' is
-- what 'Gtk.stackSetVisibleChildName' selects on, and the 'title' is
-- what a 'Gtk.StackSwitcher' shows.
data StackChildProperties =
  StackChildProperties
    { name  :: Text
    , title :: Maybe Text
    }
  deriving (Eq, Show)

-- | Defaults for 'StackChildProperties'. Use these and override
-- specific fields.
defaultStackChildProperties :: StackChildProperties
defaultStackChildProperties = StackChildProperties { name = "", title = Nothing }

instance Default StackChildProperties where
  def = defaultStackChildProperties

instance Patchable StackChild where
  create = create . child
  patch s c1 c2 | properties c1 == properties c2 = patch s (child c1) (child c2)
                | otherwise                      = Replace (create c2)

instance EventSource StackChild where
  subscribe StackChild {..} = subscribe child

instance ToChildren Gtk.Stack Vector StackChild

instance IsContainer Gtk.Stack StackChild where
  appendChild stack StackChild { properties } widget' = do
    let StackChildProperties { name, title } = properties
    _ <- Gtk.stackAddNamed stack widget' (Just name)
    case title of
      Nothing -> pure ()
      Just t  -> do
        page' <- Gtk.stackGetPage stack widget'
        Gtk.stackPageSetTitle page' t
  -- A stack has no notion of a child's position, so a replaced child
  -- is added back at the end.
  replaceChild stack stackChild' _i old new = do
    Gtk.stackRemove stack old
    appendChild stack stackChild' new
  removeChild = Gtk.stackRemove
  -- Naming the child to show only works once that child is there.
  deferredProperties _ = ["visibleChildName", "visibleChild"]
