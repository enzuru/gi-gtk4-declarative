-- Every helper below says both a specific `Gtk.Is...` constraint and
-- `Gtk.IsWidget widget`, which GHC would rather saw spelled out as
-- descendant constraints.
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Widgets that point at another widget.
--
-- A 'Gtk.StackSwitcher' switches a 'Gtk.Stack', but it does not hold
-- it: the stack lives wherever the layout puts it, which is usually not
-- next to the switcher. The usual arrangement puts the switcher in the
-- window's title bar and the stack in its body, which are different
-- parts of the tree.
--
-- So the two are joined by name. Give the widget a name with its
-- @name@ property, and point at that name from the other widget:
--
-- @
-- bin Window
--   [ titlebar $ container HeaderBar []
--       [ headerBarTitle
--           (widget StackSwitcher [switcherStack "pages"]) ]
--   ]
--   (container Stack [#name := "pages"] pages)
-- @
--
-- The name is the widget's GTK name, which is also what a CSS @#id@
-- selector matches, and what a GtkBuilder file calls an id.
--
-- A reference is resolved on the next turn of the main loop, once when
-- the tree is built and again after each patch. It waits because a
-- widget that names another is often built before it, and a lookup at
-- that moment would find nothing.
--
-- So a caller that reads the property straight after building the tree
-- reads it before it is set, and has to let the loop turn first. A
-- running application never notices, because a turn of the loop comes
-- before anything a person can do.
--
-- A name that matches nothing is reported as a warning through GLib,
-- and leaves the property unset.
--
-- For a property this module does not name, use 'reference' from
-- "GI.Gtk.Declarative.Attributes" with the setter from gi-gtk.
module GI.Gtk.Declarative.References
  ( switcherStack
  , sidebarStack
  , keyCaptureWidget
  , mnemonicWidget
  , defaultWidget
  , selectedRow
  )
where

import           Data.Text                      ( Text )
import           GHC.Ptr                        ( nullPtr )
import qualified GI.GLib                       as GLib
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes

-- | The stack a 'Gtk.StackSwitcher' switches.
switcherStack
  :: (Gtk.IsStackSwitcher widget, Gtk.IsWidget widget)
  => Text
  -> Attribute widget event
switcherStack = reference
  $ \switcher target -> Gtk.stackSwitcherSetStack switcher =<< asStack target

-- | The stack a 'Gtk.StackSidebar' lists.
sidebarStack
  :: (Gtk.IsStackSidebar widget, Gtk.IsWidget widget)
  => Text
  -> Attribute widget event
-- A sidebar's stack cannot be unset, so a name that matches nothing
-- leaves it listing whatever it listed before.
sidebarStack = reference $ \sidebar target -> do
  stack <- asStack target
  case stack of
    Nothing -> pure ()
    Just s  -> Gtk.stackSidebarSetStack sidebar s

-- | The widget whose key presses a 'Gtk.SearchBar' watches, which is
-- usually the window, so that typing anywhere starts a search.
keyCaptureWidget
  :: (Gtk.IsSearchBar widget, Gtk.IsWidget widget)
  => Text
  -> Attribute widget event
keyCaptureWidget = reference Gtk.searchBarSetKeyCaptureWidget

-- | The widget a label's mnemonic moves the focus to, so that a label
-- reading @_Name@ hands the keyboard to the entry beside it.
mnemonicWidget
  :: (Gtk.IsLabel widget, Gtk.IsWidget widget)
  => Text
  -> Attribute widget event
mnemonicWidget = reference Gtk.labelSetMnemonicWidget

-- | The widget a window activates when the user presses Enter.
defaultWidget
  :: (Gtk.IsWindow widget, Gtk.IsWidget widget)
  => Text
  -> Attribute widget event
defaultWidget = reference Gtk.windowSetDefaultWidget

-- | The row a 'Gtk.ListBox' has selected, named by its @name@
-- property.
--
-- A list box's selection is not a property, so this is the only way a
-- view can say which of its rows is the current one:
--
-- @
-- container Gtk.ListBox [selectedRow (chosen state)]
--   [ bin Gtk.ListBoxRow [#name := tool] (widget Gtk.Label [])
--   | tool <- tools
--   ]
-- @
--
-- A name that matches nothing unselects, which is how a view says that
-- nothing is chosen. Selection mode @browse@ does not answer for this:
-- it picks a row of its own only while the first row it is given is
-- one it can select, so a list with a heading row at the top starts
-- with nothing selected and a view that believes otherwise.
selectedRow
  :: (Gtk.IsListBox widget, Gtk.IsWidget widget)
  => Text
  -> Attribute widget event
selectedRow = reference $ \listBox target -> do
  box <- Gtk.toListBox listBox
  case target of
    Nothing    -> Gtk.listBoxUnselectAll box
    Just found -> do
      row <- Gtk.castTo Gtk.ListBoxRow found
      case row of
        Just row' -> Gtk.listBoxSelectRow box (Just row')
        Nothing   -> do
          name <- Gtk.widgetGetName found
          GLib.logDefaultHandler
            (Just "gi-gtk4-declarative")
            [GLib.LogLevelFlagsLevelWarning]
            (Just ("The widget named " <> name <> " is not a list box row."))
            nullPtr

-- | The widget a reference found, if it is a stack. One that is not is
-- reported, rather than thrown, because this runs on the main loop
-- where there is nobody to catch it.
asStack :: Maybe Gtk.Widget -> IO (Maybe Gtk.Stack)
asStack Nothing       = pure Nothing
asStack (Just widget') = do
  stack <- Gtk.castTo Gtk.Stack widget'
  case stack of
    Just _  -> pure stack
    Nothing -> do
      name <- Gtk.widgetGetName widget'
      GLib.logDefaultHandler
        (Just "gi-gtk4-declarative")
        [GLib.LogLevelFlagsLevelWarning]
        (Just ("The widget named " <> name <> " is not a stack."))
        nullPtr
      pure Nothing
