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
import           Control.Monad                  ( join )
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

-- * The references this module names
--
-- Each of these is one line delegating to a gi-gtk setter, and one
-- line is where a wrong name hides, so each is rendered in a window
-- and read back through the getter that goes with it.

-- | Render a window, let the main loop resolve its references, and
-- hand the window to the action.
renderWindow :: Widget Event -> (Gtk.Window -> IO a) -> IO a
renderWindow markup f = do
  window <- runUI $ do
    state <- create markup
    Gtk.unsafeCastTo Gtk.Window =<< someStateWidget state
  settle
  result <- runUI (f window)
  runUI (Gtk.windowDestroy window)
  pure result

-- | The stack a sidebar lists.
prop_a_sidebar_finds_the_stack_it_names = withTests 1 . property $ do
  found <- evalIO $ renderWindow
    (bin
      Gtk.Window
      []
      (container
        Gtk.Box
        []
        [ BoxChild defaultBoxChildProperties
          (widget Gtk.StackSidebar [sidebarStack "pages"])
        , BoxChild defaultBoxChildProperties (stackNamed "pages")
        ]
      )
    )
    (\window -> do
      sidebar <- firstOfType Gtk.StackSidebar window
      stack   <- traverse Gtk.stackSidebarGetStack sidebar
      traverse Gtk.widgetGetName (join stack)
    )
  found === Just "pages"

-- | The widget whose key presses a search bar watches, which is
-- usually the window itself.
prop_a_search_bar_finds_the_widget_it_captures_keys_from =
  withTests 1 . property $ do
    found <- evalIO $ renderWindow
      (bin
        Gtk.Window
        [#name := "the-window"]
        (bin Gtk.SearchBar
             [keyCaptureWidget "the-window"]
             (widget Gtk.SearchEntry [])
        )
      )
      (\window -> do
        bar      <- firstOfType Gtk.SearchBar window
        captured <- traverse Gtk.searchBarGetKeyCaptureWidget bar
        traverse Gtk.widgetGetName (join captured)
      )
    found === Just "the-window"

-- | The widget a label's mnemonic hands the keyboard to.
prop_a_label_finds_its_mnemonic_widget = withTests 1 . property $ do
  found <- evalIO $ renderWindow
    (bin
      Gtk.Window
      []
      (container
        Gtk.Box
        []
        [ BoxChild defaultBoxChildProperties
          (widget Gtk.Label [#label := ("_Name" :: Text), mnemonicWidget "the-entry"])
        , BoxChild defaultBoxChildProperties
                   (widget Gtk.Entry [#name := ("the-entry" :: Text)])
        ]
      )
    )
    (\window -> do
      label     <- firstOfType Gtk.Label window
      mnemonic  <- traverse Gtk.labelGetMnemonicWidget label
      traverse Gtk.widgetGetName (join mnemonic)
    )
  found === Just "the-entry"

-- | The widget a window activates when the user presses Enter.
prop_a_window_finds_its_default_widget = withTests 1 . property $ do
  found <- evalIO $ renderWindow
    (bin Gtk.Window
         [defaultWidget "the-button"]
         (widget Gtk.Button [#name := ("the-button" :: Text)])
    )
    (\window -> do
      theDefault <- Gtk.windowGetDefaultWidget window
      traverse Gtk.widgetGetName theDefault
    )
  found === Just "the-button"

-- | A reference that names a widget of the wrong kind leaves the
-- property unset, and says so through GLib rather than throwing: this
-- runs on the main loop, where there is nobody to catch it.
prop_a_reference_to_the_wrong_kind_of_widget_points_at_nothing =
  withTests 1 . property $ do
    found <- evalIO $ renderWindow
      (bin
        Gtk.Window
        []
        (container
          Gtk.Box
          []
          [ BoxChild defaultBoxChildProperties
            (widget Gtk.StackSwitcher [switcherStack "not-a-stack"])
          , BoxChild defaultBoxChildProperties
                     (widget Gtk.Label [#name := ("not-a-stack" :: Text)])
          ]
        )
      )
      (\window -> do
        switcher <- firstOfType Gtk.StackSwitcher window
        stack    <- traverse Gtk.stackSwitcherGetStack switcher
        pure (isJust (join stack))
      )
    found === False

-- | The first widget of this type below the window.
firstOfType
  :: Gtk.GObject widget
  => (Gtk.ManagedPtr widget -> widget)
  -> Gtk.Window
  -> IO (Maybe widget)
firstOfType ctor window = do
  widgets <- descendants window
  go widgets
 where
  go []       = pure Nothing
  go (w : ws) = Gtk.castTo ctor w >>= maybe (go ws) (pure . Just)

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
