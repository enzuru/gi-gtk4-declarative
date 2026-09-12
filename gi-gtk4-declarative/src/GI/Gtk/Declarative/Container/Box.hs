{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedLabels      #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

-- | Implementation of 'Gtk.Box' as a declarative container.
module GI.Gtk.Declarative.Container.Box
  ( BoxChild(..)
  , BoxChildProperties(..)
  , defaultBoxChildProperties
  , applyBoxChildProperties
  )
where

import           Data.Default.Class             ( Default(def) )
import           Data.Vector                    ( Vector )
import           Data.Word                      ( Word32 )
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Container.Class
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.Widget

-- | Describes a child widget to be added to a 'Gtk.Box'.
data BoxChild event = BoxChild
  { properties :: BoxChildProperties
  , child      :: Widget event
  }
  deriving (Functor)

-- | Values used when adding child widgets to boxes.
--
-- GTK 4 dropped the per-child packing properties that GTK 3 had, so
-- these are applied to the child widget itself, along the orientation
-- of the box: 'expand' sets @hexpand@ or @vexpand@, 'fill' sets
-- @halign@ or @valign@ to @FILL@ when true and to @CENTER@ when false,
-- and 'padding' sets the margins on the two sides that face the
-- neighbouring children.
data BoxChildProperties = BoxChildProperties
  { expand  :: Bool
  , fill    :: Bool
  , padding :: Word32
  } deriving (Eq, Show)

-- | Defaults for 'BoxChildProperties'. Use these and override
-- specific fields.
defaultBoxChildProperties :: BoxChildProperties
defaultBoxChildProperties =
  BoxChildProperties { expand = False, fill = False, padding = 0 }

instance Default BoxChildProperties where
  def = defaultBoxChildProperties

-- | Apply 'BoxChildProperties' to a child widget of a box. Exported
-- because reading them back is how the test suite checks them.
applyBoxChildProperties
  :: Gtk.Box -> BoxChildProperties -> Gtk.Widget -> IO ()
applyBoxChildProperties box BoxChildProperties { expand, fill, padding } child'
  = do
    orientation <- Gtk.orientableGetOrientation box
    let margin = fromIntegral padding
        align  = if fill then Gtk.AlignFill else Gtk.AlignCenter
    case orientation of
      Gtk.OrientationVertical -> do
        Gtk.widgetSetVexpand child' expand
        Gtk.widgetSetValign child' align
        Gtk.widgetSetMarginTop child' margin
        Gtk.widgetSetMarginBottom child' margin
      _ -> do
        Gtk.widgetSetHexpand child' expand
        Gtk.widgetSetHalign child' align
        Gtk.widgetSetMarginStart child' margin
        Gtk.widgetSetMarginEnd child' margin

instance Patchable BoxChild where
  create = create . child
  patch s b1 b2 | properties b1 == properties b2 = patch s (child b1) (child b2)
                | otherwise                      = Replace (create b2)

instance EventSource BoxChild where
  subscribe BoxChild {..} = subscribe child

instance ToChildren Gtk.Box Vector BoxChild

instance IsContainer Gtk.Box BoxChild where
  appendChild box BoxChild { properties } widget' = do
    applyBoxChildProperties box properties widget'
    Gtk.boxAppend box widget'
  replaceChild box BoxChild { properties } i old new = do
    -- The sibling the new child goes after is the one before the old
    -- child, and removing the old child does not move it.
    sibling <- childAtIndex box (i - 1)
    Gtk.boxRemove box old
    applyBoxChildProperties box properties new
    Gtk.boxInsertChildAfter box new sibling
  removeChild = Gtk.boxRemove
  reapplyChild box BoxChild { properties } = applyBoxChildProperties box properties
