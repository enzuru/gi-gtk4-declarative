{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors -fno-warn-orphans #-}

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedLabels      #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

-- | Implementation of 'Gtk.Paned' as a declarative container.
module GI.Gtk.Declarative.Container.Paned
  ( Pane
  , PaneProperties(..)
  , defaultPaneProperties
  , pane
  , paned
  )
where

import           Data.Default.Class             ( Default(def) )
import           Data.Text                      ( Text )
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import           GHC.Ptr                        ( nullPtr )
import qualified GI.GLib                       as GLib
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Container
import           GI.Gtk.Declarative.Container.Class
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.Widget

-- | Describes a pane to be packed as the start or the end child of a
-- 'Gtk.Paned'.
data Pane event = Pane
  { paneProperties :: PaneProperties
  , paneChild      :: Widget event
  }
  deriving (Functor)

-- | Values used when packing a pane into a 'Gtk.Paned'.
data PaneProperties = PaneProperties
  { resize :: Bool
  , shrink :: Bool
  }

-- | Defaults for 'PaneProperties'. Use these and override specific
-- fields.
defaultPaneProperties :: PaneProperties
defaultPaneProperties = PaneProperties { resize = False, shrink = True }

instance Default PaneProperties where
  def = defaultPaneProperties

-- | Construct a pane to be packed in a 'Gtk.Paned'.
pane :: PaneProperties -> Widget event -> Pane event
pane paneProperties paneChild = Pane { .. }

instance Patchable Pane where
  create = create . paneChild
  patch s b1 b2 = patch s (paneChild b1) (paneChild b2)

instance EventSource Pane where
  subscribe Pane {..} = subscribe paneChild

-- | Construct a 'Gtk.Paned' based on attributes and two child 'Pane's.
paned
  :: Vector (Attribute Gtk.Paned event)
  -> Pane event
  -> Pane event
  -> Widget event
paned attrs p1 p2 = container Gtk.Paned attrs (Panes p1 p2)

data Panes child = Panes child child
  deriving (Functor)

tooManyPanes :: Text -> IO ()
tooManyPanes caller = GLib.logDefaultHandler
  (Just "gi-gtk-declarative")
  [GLib.LogLevelFlagsLevelWarning]
  (Just
    (caller
    <> ": The `GI.Gtk.Paned` widget can only fit 2 panes. Additional children will be ignored."
    )
  )
  nullPtr

setPane
  :: Gtk.Paned -> Int -> PaneProperties -> Maybe Gtk.Widget -> IO ()
setPane paned' 0 PaneProperties { resize, shrink } widget' = do
  Gtk.panedSetStartChild paned' widget'
  Gtk.panedSetResizeStartChild paned' resize
  Gtk.panedSetShrinkStartChild paned' shrink
setPane paned' _ PaneProperties { resize, shrink } widget' = do
  Gtk.panedSetEndChild paned' widget'
  Gtk.panedSetResizeEndChild paned' resize
  Gtk.panedSetShrinkEndChild paned' shrink

instance IsContainer Gtk.Paned Pane where
  appendChild paned' Pane { paneProperties } widget' = do
    c1 <- Gtk.panedGetStartChild paned'
    c2 <- Gtk.panedGetEndChild paned'
    case (c1, c2) of
      (Nothing, Nothing) -> setPane paned' 0 paneProperties (Just widget')
      (Just _ , Nothing) -> setPane paned' 1 paneProperties (Just widget')
      _                  -> tooManyPanes "appendChild"
  replaceChild paned' Pane { paneProperties } i _old new = case i of
    0 -> setPane paned' 0 paneProperties (Just new)
    1 -> setPane paned' 1 paneProperties (Just new)
    _ -> tooManyPanes "replaceChild"
  removeChild paned' widget' = do
    c1 <- Gtk.panedGetStartChild paned'
    if c1 == Just widget'
      then Gtk.panedSetStartChild paned' (Nothing :: Maybe Gtk.Widget)
      else Gtk.panedSetEndChild paned' (Nothing :: Maybe Gtk.Widget)

instance ToChildren Gtk.Paned Panes Pane where
  toChildren _ (Panes p1 p2) = Children (Vector.fromList [p1, p2])
