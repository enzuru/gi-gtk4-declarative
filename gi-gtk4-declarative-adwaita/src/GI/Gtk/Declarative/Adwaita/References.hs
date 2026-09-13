-- Every helper below says both a specific `Adw.Is...` constraint and
-- `Gtk.IsWidget widget`, which GHC would rather saw spelled out as
-- descendant constraints.
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The libadwaita widgets that point at another widget.
--
-- An @AdwTabBar@ shows the tabs of an @AdwTabView@, which it does not
-- hold: the view is wherever the layout puts it, which is under the
-- bar rather than in it. So the two are joined by name, the way
-- "GI.Gtk.Declarative.References" joins a stack switcher to its stack:
--
-- @
-- container Adw.ToolbarView []
--   [ toolbarTop (widget Adw.TabBar [tabBarView "sheets"])
--   , toolbarContent (tabView [#name := "sheets"] theTabs)
--   ]
-- @
--
-- The name is the widget's GTK name, which is also what a CSS @#id@
-- selector matches.
--
-- A reference is resolved once the tree is built, and again after each
-- patch. A name that matches nothing is reported as a warning through
-- GLib, and leaves the property unset.
module GI.Gtk.Declarative.Adwaita.References
  ( tabBarView
  , tabOverviewView
  )
where

import           Data.Text                      ( Text )
import           GHC.Ptr                        ( nullPtr )
import qualified GI.Adw                        as Adw
import qualified GI.GLib                       as GLib
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes

-- | The tab view an @AdwTabBar@ shows the tabs of.
tabBarView
  :: (Adw.IsTabBar widget, Gtk.IsWidget widget)
  => Text
  -> Attribute widget event
tabBarView =
  reference $ \bar target -> Adw.tabBarSetView bar =<< asTabView target

-- | The tab view an @AdwTabOverview@ shows the pages of.
tabOverviewView
  :: (Adw.IsTabOverview widget, Gtk.IsWidget widget)
  => Text
  -> Attribute widget event
tabOverviewView = reference
  $ \overview target -> Adw.tabOverviewSetView overview =<< asTabView target

-- | The widget a reference found, if it is a tab view. One that is not
-- is reported, rather than thrown, because this runs on the main loop
-- where there is nobody to catch it.
asTabView :: Maybe Gtk.Widget -> IO (Maybe Adw.TabView)
asTabView Nothing        = pure Nothing
asTabView (Just widget') = do
  view <- Gtk.castTo Adw.TabView widget'
  case view of
    Just _  -> pure view
    Nothing -> do
      name <- Gtk.widgetGetName widget'
      GLib.logDefaultHandler
        (Just "gi-gtk4-declarative-adwaita")
        [GLib.LogLevelFlagsLevelWarning]
        (Just ("The widget named " <> name <> " is not a tab view."))
        nullPtr
      pure Nothing
