-- Both helpers below say `Adw.IsToolbarView widget` and
-- `Gtk.IsWidget widget`, which GHC would rather saw spelled out as
-- descendant constraints.
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The bars of a toolbar view.
--
-- An @AdwToolbarView@ holds a content child, which is what
-- 'GI.Gtk.Declarative.Bin.bin' sets, and any number of bars above and
-- below it:
--
-- @
-- bin Adw.ToolbarView
--   [ toolbarTopBar (container Adw.HeaderBar [] [])
--   , toolbarBottomBar (container Adw.ActionBar [] [])
--   ]
--   theContent
-- @
--
-- One bar at each end is what these two slots give. A view with more
-- than one bar at an end is added with @adw_toolbar_view_add_top_bar@
-- by hand, from 'GI.Gtk.Declarative.Attributes.afterCreated'.
module GI.Gtk.Declarative.Adwaita.Slots
  ( toolbarTopBar
  , toolbarBottomBar
  )
where

import           Control.Monad                  ( when )
import           Data.Foldable                  ( for_ )
import           Data.GI.Base                   ( newObject
                                                , withManagedPtr
                                                )
import           Data.Text                      ( Text )
import           Foreign.Ptr                    ( Ptr
                                                , castPtr
                                                , nullPtr
                                                )
import qualified GI.Adw                        as Adw
import qualified GI.GObject                    as GI
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Widget

-- | The bar above the content, added with
-- @adw_toolbar_view_add_top_bar@.
toolbarTopBar
  :: (Adw.IsToolbarView widget, Gtk.IsWidget widget)
  => Widget event
  -> Attribute widget event
toolbarTopBar = slot topBarKey (setBar topBarKey Adw.toolbarViewAddTopBar)

-- | The bar below the content, added with
-- @adw_toolbar_view_add_bottom_bar@.
toolbarBottomBar
  :: (Adw.IsToolbarView widget, Gtk.IsWidget widget)
  => Widget event
  -> Attribute widget event
toolbarBottomBar =
  slot bottomBarKey (setBar bottomBarKey Adw.toolbarViewAddBottomBar)

topBarKey :: Text
topBarKey = "gi-gtk4-declarative-top-bar"

bottomBarKey :: Text
bottomBarKey = "gi-gtk4-declarative-bottom-bar"

-- | Put a bar at one end of a toolbar view, in place of the bar that
-- is there.
--
-- A toolbar view has no getter for its bars, and the widgets it puts
-- them in are its own business, so the bar this library last added is
-- remembered on the view itself, under the slot's name, with
-- @g_object_set_data@. The bar stays parented until it is taken away
-- here, which is what makes it safe to read again.
setBar
  :: forall widget
   . Adw.IsToolbarView widget
  => Text
  -> (Adw.ToolbarView -> Gtk.Widget -> IO ())
  -> widget
  -> Maybe Gtk.Widget
  -> IO ()
setBar key add widget' newBar = do
  view     <- Adw.toToolbarView widget'
  previous <- GI.objectGetData view key
  when (previous /= nullPtr) $ do
    old <- newObject Gtk.Widget (castPtr previous :: Ptr Gtk.Widget)
    Adw.toolbarViewRemove view old
    GI.objectSetData view key nullPtr
  for_ newBar $ \bar -> do
    add view bar
    withManagedPtr bar $ \ptr -> GI.objectSetData view key (castPtr ptr)
