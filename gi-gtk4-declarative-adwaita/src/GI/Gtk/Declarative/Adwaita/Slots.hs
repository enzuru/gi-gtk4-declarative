-- Both helpers below say `Adw.IsToolbarView widget` and
-- `Gtk.IsWidget widget`, which GHC would rather saw spelled out as
-- descendant constraints.
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Widget-valued properties of the libadwaita widgets.
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
  , titleWidget
  , splitViewSidebar
  , splitViewContent
  , overlaySidebar
  , overlayContent
  , presentedDialog
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

-- | The widget in the middle of an @AdwHeaderBar@, in place of the
-- window's title. An @AdwWindowTitle@ is what usually goes here.
titleWidget
  :: (Adw.IsHeaderBar widget, Gtk.IsWidget widget)
  => Widget event
  -> Attribute widget event
titleWidget = slot "title-widget" Adw.headerBarSetTitleWidget

-- | The sidebar page of an @AdwNavigationSplitView@, which is the
-- widget a window of two panes is usually built from.
--
-- The widget in this slot has to be an @AdwNavigationPage@, which is
-- checked when the view is rendered.
splitViewSidebar
  :: (Adw.IsNavigationSplitView widget, Gtk.IsWidget widget)
  => Widget event
  -> Attribute widget event
splitViewSidebar =
  slot "sidebar" (setPage Adw.navigationSplitViewSetSidebar)

-- | The content page of an @AdwNavigationSplitView@, beside the
-- sidebar. It has to be an @AdwNavigationPage@ as well.
splitViewContent
  :: (Adw.IsNavigationSplitView widget, Gtk.IsWidget widget)
  => Widget event
  -> Attribute widget event
splitViewContent =
  slot "content" (setPage Adw.navigationSplitViewSetContent)

-- | The sidebar of an @AdwOverlaySplitView@, which is the same shape
-- as a navigation split view and takes any widget rather than a page.
overlaySidebar
  :: (Adw.IsOverlaySplitView widget, Gtk.IsWidget widget)
  => Widget event
  -> Attribute widget event
overlaySidebar = slot "sidebar" Adw.overlaySplitViewSetSidebar

-- | The content of an @AdwOverlaySplitView@, beside its sidebar.
overlayContent
  :: (Adw.IsOverlaySplitView widget, Gtk.IsWidget widget)
  => Widget event
  -> Attribute widget event
overlayContent = slot "content" Adw.overlaySplitViewSetContent

-- | The dialog this widget is showing, if it is showing one.
--
-- An @AdwDialog@ is neither a child nor a property: it is presented
-- over a widget with @adw_dialog_present@, and it takes itself down
-- again. So a view has nowhere to say which dialog is open, and a
-- program that wants to say it reaches past this library and keeps the
-- dialog by hand. This is that place:
--
-- @
-- bin Adw.ApplicationWindow
--   (  [#title := "Toolchains"]
--   <> foldMap (\open -> [presentedDialog (dialogFor state open)]) (dialog state)
--   )
--   content
-- @
--
-- The dialog in the slot lives the life of any other widget in a slot.
-- It is created with the window, patched while it is open, so that its
-- contents follow the state, and subscribed to for its events. When
-- the view stops naming a dialog, the slot is emptied, and emptying it
-- closes the dialog.
--
-- A dialog somebody closed with Escape is already gone, so closing it
-- again would be a warning. This asks the dialog whether it still has
-- a parent before it says anything to it.
--
-- The widget in the slot has to be an @AdwDialog@, which is checked
-- when it is rendered. The widget the slot is on can be any widget in
-- a window, which is what @adw_dialog_present@ takes.
presentedDialog
  :: Gtk.IsWidget widget => Widget event -> Attribute widget event
presentedDialog = slot dialogKey setDialog

dialogKey :: Text
dialogKey = "gi-gtk4-declarative-presented-dialog"

-- | Present a dialog over a widget, in place of the dialog that is
-- there.
--
-- A dialog is not the widget's child, so the widget is told which one
-- it last presented, with @g_object_set_data@, as a toolbar view is
-- told about its bars.
setDialog :: Gtk.IsWidget widget => widget -> Maybe Gtk.Widget -> IO ()
setDialog widget' newDialog = do
  parent   <- Gtk.toWidget widget'
  previous <- GI.objectGetData parent dialogKey
  when (previous /= nullPtr) $ do
    old <- newObject Adw.Dialog (castPtr previous :: Ptr Adw.Dialog)
    GI.objectSetData parent dialogKey nullPtr
    -- A dialog somebody closed already has no parent, and asking it to
    -- close again is a warning worth not causing.
    stillOpen <- Gtk.widgetGetParent old
    for_ stillOpen $ \_ -> Adw.dialogForceClose old
  for_ newDialog $ \child -> do
    dialog <- Gtk.unsafeCastTo Adw.Dialog child
    withManagedPtr dialog
      $ \ptr -> GI.objectSetData parent dialogKey (castPtr ptr)
    Adw.dialogPresent dialog (Just parent)

-- | Put a widget in a property that holds a navigation page, casting
-- it on the way. A widget that is not a page is a failure here rather
-- than a warning from libadwaita afterwards.
setPage
  :: (view -> Maybe Adw.NavigationPage -> IO ())
  -> view
  -> Maybe Gtk.Widget
  -> IO ()
setPage set view child = do
  page <- traverse (Gtk.unsafeCastTo Adw.NavigationPage) child
  set view page

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
