-- The instances below are orphans: the class comes from the core
-- package and the widgets come from gi-adwaita, so this module owns
-- neither. That is the point of the package, and importing it is what
-- brings the instances in.
{-# OPTIONS_GHC -Wno-orphans #-}

-- | The libadwaita widgets that hold exactly one child.
--
-- Each of these is used with 'GI.Gtk.Declarative.Bin.bin', the same way
-- a 'GI.Gtk.Window' is:
--
-- @
-- bin Adw.ApplicationWindow [#title := "Cellar"]
--   (bin Adw.ToolbarView [toolbarTopBar theHeader] theContent)
-- @
--
-- Import this module for its instances. It exports nothing.
--
-- An @AdwApplicationWindow@ holds its child in the /content/ property
-- rather than in the window's own child property, and the two are not
-- the same: @gtk_window_set_child@ on one of these replaces the
-- window's whole content, style manager and all, which GTK reports as
-- a warning at run time rather than as an error. The instances here
-- call @adw_application_window_set_content@, so this is a mistake a
-- program using them does not make.
module GI.Gtk.Declarative.Adwaita.Bin
  (
  )
where

import qualified GI.Adw                        as Adw

import           GI.Gtk.Declarative.Bin         ( IsBin(..) )

instance IsBin Adw.ApplicationWindow where
  setBinChild = Adw.applicationWindowSetContent
  getBinChild = Adw.applicationWindowGetContent

instance IsBin Adw.Window where
  setBinChild = Adw.windowSetContent
  getBinChild = Adw.windowGetContent

instance IsBin Adw.ToastOverlay where
  setBinChild = Adw.toastOverlaySetChild
  getBinChild = Adw.toastOverlayGetChild

instance IsBin Adw.Bin where
  setBinChild = Adw.binSetChild
  getBinChild = Adw.binGetChild

instance IsBin Adw.StatusPage where
  setBinChild = Adw.statusPageSetChild
  getBinChild = Adw.statusPageGetChild

instance IsBin Adw.Clamp where
  setBinChild = Adw.clampSetChild
  getBinChild = Adw.clampGetChild

instance IsBin Adw.Dialog where
  setBinChild = Adw.dialogSetChild
  getBinChild = Adw.dialogGetChild

-- | A page of an @AdwNavigationView@ or an @AdwNavigationSplitView@,
-- which holds the widget that is on that page.
instance IsBin Adw.NavigationPage where
  setBinChild = Adw.navigationPageSetChild
  getBinChild = Adw.navigationPageGetChild

-- | The child an @AdwTabOverview@ shows when it is not open, which is
-- the tab view itself or something holding it.
instance IsBin Adw.TabOverview where
  setBinChild = Adw.tabOverviewSetChild
  getBinChild = Adw.tabOverviewGetChild

-- | The /content/ of a toolbar view. Its bars are separate, and go in
-- the slots from "GI.Gtk.Declarative.Adwaita.Slots".
instance IsBin Adw.ToolbarView where
  setBinChild = Adw.toolbarViewSetContent
  getBinChild = Adw.toolbarViewGetContent
