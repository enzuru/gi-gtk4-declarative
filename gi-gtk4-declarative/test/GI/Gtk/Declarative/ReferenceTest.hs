{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for widgets that point at another widget.
--
-- A stack switcher in a window's title bar and the stack it switches in
-- the window's body are in different parts of the tree, joined only by
-- a name. Resolving that name has to wait until the tree is whole,
-- which is what these check.
module GI.Gtk.Declarative.ReferenceTest where

import           Control.Exception.Safe         ( bracket )
import           Data.Maybe                     ( isJust )
import           Data.Text                      ( Text )
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Container.Class
                                                ( childWidgets )
import           GI.Gtk.Declarative.Container.HeaderBar
import           GI.Gtk.Declarative.Container.Stack
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.TestUtils

data Event = Closed
  deriving (Eq, Show)

-- | A window whose title bar holds a stack switcher, and whose body
-- holds two stacks, named "first" and "second".
windowPointingAt :: Text -> Widget Event
windowPointingAt name = bin
  Gtk.Window
  [ titlebar $ container
      Gtk.HeaderBar
      []
      [headerBarTitle (widget Gtk.StackSwitcher [switcherStack name])]
  ]
  (container
    Gtk.Box
    []
    [ BoxChild defaultBoxChildProperties (stackNamed "first")
    , BoxChild defaultBoxChildProperties (stackNamed "second")
    ]
  )

stackNamed :: Text -> Widget Event
stackNamed name = container
  Gtk.Stack
  [#name := name]
  (pages name)

pages :: Text -> Vector (StackChild Event)
pages name =
  [ StackChild defaultStackChildProperties { name = "one", title = Just "One" }
               (widget Gtk.Label [#label := name])
  ]

-- | The switcher, and the stack it points at, as GTK objects.
switcherAndStack :: Gtk.Window -> IO (Gtk.StackSwitcher, Maybe Gtk.Widget)
switcherAndStack window = do
  bar      <- Gtk.windowGetTitlebar window
  header   <- maybe (fail "no title bar") (Gtk.unsafeCastTo Gtk.HeaderBar) bar
  title    <- Gtk.headerBarGetTitleWidget header
  switcher <- maybe (fail "no title widget")
                    (Gtk.unsafeCastTo Gtk.StackSwitcher)
                    title
  stack    <- Gtk.stackSwitcherGetStack switcher
  (,) switcher <$> traverse Gtk.toWidget stack

prop_a_switcher_finds_the_stack_it_names = withTests 1 . property $ do
  (found, isTheRightOne) <- evalIO $ do
    (window, _) <- runUI $ do
      state  <- create (windowPointingAt "second")
      window <- Gtk.unsafeCastTo Gtk.Window =<< someStateWidget state
      pure (window, state)
    -- The tree is whole now, so the reference can be resolved.
    settle
    result <- runUI $ do
      (_, pointsAt') <- switcherAndStack window
      second'        <- namedBelow window "second"
      Gtk.windowDestroy window
      pure (isJust pointsAt', isJust second' && pointsAt' == second')
    pure result
  found === True
  isTheRightOne === True

prop_a_patched_reference_points_at_the_other_stack = withTests 1 . property $ do
  (found, isTheRightOne) <- evalIO $ do
    (window, state) <- runUI $ do
      state  <- create (windowPointingAt "first")
      window <- Gtk.unsafeCastTo Gtk.Window =<< someStateWidget state
      pure (window, state)
    settle
    _ <- runUI
      (patch' state (windowPointingAt "first") (windowPointingAt "second"))
    settle
    runUI $ do
      (_, pointsAt') <- switcherAndStack window
      second'        <- namedBelow window "second"
      Gtk.windowDestroy window
      pure (isJust pointsAt', isJust second' && pointsAt' == second')
  found === True
  isTheRightOne === True

prop_a_reference_that_names_nothing_points_at_nothing = withTests 1 . property $ do
  found <- evalIO $ do
    window <- runUI $ do
      state <- create (windowPointingAt "no-such-stack")
      Gtk.unsafeCastTo Gtk.Window =<< someStateWidget state
    settle
    runUI $ do
      (_, pointsAt') <- switcherAndStack window
      Gtk.windowDestroy window
      pure (isJust pointsAt')
  found === False

-- | The widget with this name anywhere below the window.
namedBelow :: Gtk.Window -> Text -> IO (Maybe Gtk.Widget)
namedBelow window name = Gtk.toWidget window >>= go
 where
  go w = do
    this <- Gtk.widgetGetName w
    if this == name
      then pure (Just w)
      else do
        children <- childWidgetsOf w
        firstOf children
  firstOf []       = pure Nothing
  firstOf (w : ws) = go w >>= maybe (firstOf ws) (pure . Just)
  childWidgetsOf w = Vector.toList <$> childWidgets w

-- * Test collection

tests :: IO Bool
tests = checkParallel $$(discover)
