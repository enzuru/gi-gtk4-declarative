{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for the widgets that hold exactly one child.
--
-- GTK 4 gave every such widget a setter of its own, and an 'IsBin'
-- instance is two lines naming the pair for one widget. Two lines are
-- where a wrong name hides: @gtk_window_set_child@ on a widget that
-- wants something else is a warning at run time rather than an error,
-- and nothing else in the suite reads these back.
--
-- So this renders a child into every widget with an instance, and asks
-- the instance itself for it again.
module GI.Gtk.Declarative.BinTest where

import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Data.Typeable                  ( Typeable )
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Bin         ( IsBin(..) )
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.TestUtils

-- | What the child says, so that the widget that was asked for it can
-- be told from a widget that answered with something else.
inside :: Text
inside = "inside"

-- | One widget that holds a child: what to call it, what it should
-- answer with when it is asked for its child, and the asking.
data BinCase = BinCase
  { caseName     :: Text
  , caseExpected :: Text
  , caseRun      :: IO Text
  }

binCase
  :: (Typeable widget, IsBin widget, Gtk.IsWidget widget)
  => Text
  -> (Gtk.ManagedPtr widget -> widget)
  -> BinCase
binCase name ctor = BinCase name inside $ do
  (parent, found) <- runUI $ do
    let markup = bin ctor [] (widget Gtk.Label [#label := inside]) :: Widget ()
    state <- create markup
    built <- someStateWidget state
    typed <- Gtk.unsafeCastTo ctor built
    (,) built <$> getBinChild typed
  answer <- runUI (maybe (pure "nothing") describeChild found)
  runUI (takeDown parent)
  pure answer

-- | What a child reads as: what it says, if it is a label, and what
-- kind of widget it is otherwise, which is what a widget's name is
-- before anybody sets one.
describeChild :: Gtk.Widget -> IO Text
describeChild widget' = do
  label <- labelOf widget'
  if Text.null label then Gtk.widgetGetName widget' else pure label

-- | A window has to be destroyed; anything else goes when the last
-- reference to it does.
takeDown :: Gtk.Widget -> IO ()
takeDown widget' = do
  window <- Gtk.castTo Gtk.Window widget'
  mapM_ Gtk.windowDestroy window

-- | Every widget with an instance in "GI.Gtk.Declarative.Bin".
cases :: [BinCase]
cases =
  [ binCase "Window"           Gtk.Window
  , binCase "ApplicationWindow" Gtk.ApplicationWindow
  , binCase "Frame"            Gtk.Frame
  , binCase "AspectFrame"      Gtk.AspectFrame
  , binCase "Button"           Gtk.Button
  , binCase "ToggleButton"     Gtk.ToggleButton
  , binCase "LinkButton"       Gtk.LinkButton
  , binCase "CheckButton"      Gtk.CheckButton
  , binCase "MenuButton"       Gtk.MenuButton
  , binCase "Expander"         Gtk.Expander
  , binCase "Revealer"         Gtk.Revealer
  -- A scrolled window puts a child that does not scroll in a viewport
  -- of its own, and answers with the viewport rather than with the
  -- child, which is GTK's doing and worth knowing about.
  , (binCase "ScrolledWindow" Gtk.ScrolledWindow)
    { caseExpected = "GtkViewport"
    }
  , binCase "Viewport"         Gtk.Viewport
  , binCase "Popover"          Gtk.Popover
  , binCase "ListBoxRow"       Gtk.ListBoxRow
  , binCase "FlowBoxChild"     Gtk.FlowBoxChild
  , binCase "SearchBar"        Gtk.SearchBar
  , binCase "WindowHandle"     Gtk.WindowHandle
  , binCase "Overlay"          Gtk.Overlay
  ]

prop_every_bin_holds_the_child_it_was_given = withTests 1 . property $ do
  answers <- evalIO (traverse run cases)
  answers === map (\theCase -> (caseName theCase, caseExpected theCase)) cases
  where run theCase = (,) (caseName theCase) <$> caseRun theCase

-- | A child that is replaced by a widget of another type is put in the
-- same place, for a bin as for a container.
prop_a_bin_takes_the_child_it_is_patched_with = withTests 1 . property $ do
  labels <- evalIO $ do
    let first = bin Gtk.Frame [] (widget Gtk.Label [#label := inside]) :: Widget ()
        second =
          bin Gtk.Frame [] (widget Gtk.Button [#label := ("a button" :: Text)])
    state   <- runUI (create first)
    _       <- runUI (patch' state first second)
    widget' <- runUI (someStateWidget state)
    runUI (descendantLabels widget')
  labels === ["a button"]

tests :: IO Bool
tests = checkParallel $$(discover)
