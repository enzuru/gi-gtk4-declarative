{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for the libadwaita containers: the header bar and the
-- toolbar view.
module GI.Gtk.Declarative.Adwaita.ContainerTest where

import           Data.Text                      ( Text )
import qualified GI.Adw                        as Adw
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Adwaita.HeaderBar
import           GI.Gtk.Declarative.Adwaita.Slots
import           GI.Gtk.Declarative.Adwaita.TestUtils
import           GI.Gtk.Declarative.Adwaita.ToolbarView
import           GI.Gtk.Declarative.State

label :: Text -> Widget event
label text = widget Gtk.Label [#label := text]

-- | Render the first markup, patch it with the others in turn, and
-- hand the widget to the action.
render :: [Widget ()] -> (Gtk.Widget -> IO a) -> IO a
render []             _ = fail "render: no markup to render"
render (first : rest) f = do
  state  <- runUI (create first)
  state' <- step (state, first) rest
  view   <- runUI (someStateWidget state')
  runUI (f view)
 where
  step (state, _  ) []           = pure state
  step (state, old) (new : more) = do
    patched <- runUI (patch' state old new)
    step (patched, new) more

-- * The header bar

prop_a_header_bar_packs_start_and_end = withTests 1 . property $ do
  labels <- evalIO $ render
    [ container
        Adw.HeaderBar
        [titleWidget (label "the title")]
        [headerBarStart (label "left"), headerBarEnd (label "right")]
    ]
    descendantLabels
  labels === ["left", "the title", "right"]

prop_a_header_bar_child_is_patched = withTests 1 . property $ do
  labels <- evalIO $ render
    [ container Adw.HeaderBar [] [headerBarStart (label "before")]
    , container Adw.HeaderBar [] [headerBarStart (label "after")]
    ]
    descendantLabels
  labels === ["after"]

prop_a_header_bar_child_that_goes_away_is_removed = withTests 1 . property $ do
  labels <- evalIO $ render
    [ container
      Adw.HeaderBar
      []
      [ headerBarStart (label "one")
      , headerBarStart (label "two")
      , headerBarEnd (label "three")
      ]
    , container Adw.HeaderBar [] [headerBarStart (label "one")]
    ]
    descendantLabels
  labels === ["one"]

-- * The toolbar view

prop_a_toolbar_view_holds_bars_and_content = withTests 1 . property $ do
  labels <- evalIO $ render
    [ container
        Adw.ToolbarView
        []
        [ toolbarTop (label "header")
        , toolbarTop (label "tabs")
        , toolbarContent (label "the content")
        , toolbarBottom (label "status")
        ]
    ]
    descendantLabels
  labels === ["the content", "header", "tabs", "status"]

prop_a_toolbar_bar_is_patched = withTests 1 . property $ do
  labels <- evalIO $ render
    [ container
      Adw.ToolbarView
      []
      [toolbarTop (label "before"), toolbarContent (label "the content")]
    , container
      Adw.ToolbarView
      []
      [toolbarTop (label "after"), toolbarContent (label "the content")]
    ]
    descendantLabels
  labels === ["the content", "after"]

prop_a_toolbar_bar_that_goes_away_is_removed = withTests 1 . property $ do
  labels <- evalIO $ render
    [ container
      Adw.ToolbarView
      []
      [ toolbarTop (label "one")
      , toolbarTop (label "two")
      , toolbarContent (label "the content")
      ]
    , container
      Adw.ToolbarView
      []
      [toolbarTop (label "one"), toolbarContent (label "the content")]
    ]
    descendantLabels
  labels === ["the content", "one"]

tests :: IO Bool
tests = checkParallel $$(discover)
