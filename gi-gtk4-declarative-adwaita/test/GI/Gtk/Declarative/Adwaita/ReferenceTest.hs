{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for the libadwaita widgets that point at another widget.
--
-- A tab bar and the tab view whose tabs it shows are in different
-- parts of the tree, joined only by a name, so resolving that name has
-- to wait until the tree is whole.
module GI.Gtk.Declarative.Adwaita.ReferenceTest where

import           Data.Text                      ( Text )
import qualified GI.Adw                        as Adw
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Adwaita.References
import           GI.Gtk.Declarative.Adwaita.Bin ( )
import           GI.Gtk.Declarative.Adwaita.TabView
import           GI.Gtk.Declarative.Adwaita.TestUtils
import           GI.Gtk.Declarative.Adwaita.ToolbarView
import           GI.Gtk.Declarative.State

-- | A toolbar view whose top bar is a tab bar pointing at this name,
-- and whose content is a tab view named "sheets".
barPointingAt :: Text -> Widget ()
barPointingAt name = container
  Adw.ToolbarView
  []
  [ toolbarTop (widget Adw.TabBar [tabBarView name])
  , toolbarContent
    (tabView
      [#name := ("sheets" :: Text)]
      defaultTabViewParams
        { tabs = [Tab "a" "First" (widget Gtk.Label [#label := ("one" :: Text)])]
        }
    )
  ]

-- | The tab bar of a rendered toolbar view, and the view it points at.
barAndView :: Gtk.Widget -> IO (Adw.TabBar, Maybe Adw.TabView)
barAndView view = do
  bars <- descendants view
  bar  <- firstTabBar bars
  (,) bar <$> Adw.tabBarGetView bar
 where
  firstTabBar [] = fail "no tab bar in the view"
  firstTabBar (candidate : rest) = do
    found <- Gtk.castTo Adw.TabBar candidate
    maybe (firstTabBar rest) pure found

-- | Render markup, patch it with the rest, and hand the widget over.
render :: [Widget ()] -> (Gtk.Widget -> IO a) -> IO a
render []             _ = fail "render: no markup to render"
render (first : rest) f = do
  state   <- runUI (create first)
  state'  <- step (state, first) rest
  widget' <- runUI (someStateWidget state')
  -- A reference is resolved on the main loop once the tree is whole.
  settle
  runUI (f widget')
 where
  step (state, _  ) []           = pure state
  step (state, old) (new : more) = do
    patched <- runUI (patch' state old new)
    settle
    step (patched, new) more

prop_a_tab_bar_finds_the_view_it_names = withTests 1 . property $ do
  (found, sameName) <- evalIO $ render [barPointingAt "sheets"] $ \widget' -> do
    (_bar, view) <- barAndView widget'
    name         <- traverse Gtk.widgetGetName view
    pure (maybe False (const True) view, name)
  found === True
  sameName === Just "sheets"

-- | A name that matches nothing leaves the property unset, rather than
-- pointing at whatever was there before.
prop_a_tab_bar_that_names_nothing_points_at_nothing =
  withTests 1 . property $ do
    found <- evalIO $ render [barPointingAt "no-such-view"] $ \widget' -> do
      (_bar, view) <- barAndView widget'
      pure (maybe False (const True) view)
    found === False

-- | A patched reference points at what the new name says.
prop_a_patched_reference_points_at_the_other_view =
  withTests 1 . property $ do
    found <-
      evalIO
      $ render [barPointingAt "no-such-view", barPointingAt "sheets"]
      $ \widget' -> do
          (_bar, view) <- barAndView widget'
          traverse Gtk.widgetGetName view
    found === Just "sheets"

-- | A tab overview points at a view by name in the same way a tab bar
-- does.
prop_a_tab_overview_finds_the_view_it_names = withTests 1 . property $ do
  found <- evalIO $ render
    [ bin
        Adw.TabOverview
        [tabOverviewView "sheets"]
        (tabView
          [#name := ("sheets" :: Text)]
          defaultTabViewParams
            { tabs =
              [Tab "a" "First" (widget Gtk.Label [#label := ("one" :: Text)])]
            }
        )
    ]
    (\widget' -> do
      overview <- Gtk.unsafeCastTo Adw.TabOverview widget'
      view     <- Adw.tabOverviewGetView overview
      traverse Gtk.widgetGetName view
    )
  found === Just "sheets"

-- | A name that points at a widget of the wrong kind leaves the
-- property unset, and says so through GLib.
prop_a_tab_bar_that_names_the_wrong_kind_points_at_nothing =
  withTests 1 . property $ do
    found <- evalIO $ render
      [ container
          Adw.ToolbarView
          []
          [ toolbarTop (widget Adw.TabBar [tabBarView "not-a-view"])
          , toolbarContent
            (widget Gtk.Label [#name := ("not-a-view" :: Text)])
          ]
      ]
      (\widget' -> do
        (_bar, view) <- barAndView widget'
        pure (maybe False (const True) view)
      )
    found === False

tests :: IO Bool
tests = checkParallel $$(discover)
