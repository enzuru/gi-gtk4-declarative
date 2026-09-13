{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for the libadwaita containers: the header bar and the
-- toolbar view.
module GI.Gtk.Declarative.Adwaita.ContainerTest where

import qualified Data.List                     as List
import           Data.Maybe                     ( catMaybes
                                                , listToMaybe
                                                )
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

-- | A child of a header bar that cannot be patched is built again and
-- packed back at its own end.
prop_a_header_bar_child_that_is_replaced_keeps_its_end = withTests 1 . property $ do
  labels <- evalIO $ render
    [ container
      Adw.HeaderBar
      []
      [headerBarStart (label "left"), headerBarEnd (label "right")]
    , container
      Adw.HeaderBar
      []
      [ headerBarStart (widget Gtk.Button [#label := ("LEFT" :: Text)])
      , headerBarEnd (label "right")
      ]
    ]
    descendantLabels
  labels === ["LEFT", "right"]

-- | A child that changes which end it is at is built again, because
-- where a child is packed is not something a patch can change.
prop_a_header_bar_child_that_changes_end_is_built_again =
  withTests 1 . property $ do
    (built, labels) <- evalIO $ do
      let bar children = container Adw.HeaderBar [] children :: Widget ()
          atStart =
            bar [headerBarStart (label "moving"), headerBarEnd (label "fixed")]
          atEnd =
            bar [headerBarEnd (label "moving"), headerBarEnd (label "fixed")]
      state   <- runUI (create atStart)
      widget' <- runUI (someStateWidget state)
      before  <- runUI (labelNamed widget' "moving")
      _       <- runUI (patch' state atStart atEnd)
      after   <- runUI (labelNamed widget' "moving")
      labels' <- runUI (descendantLabels widget')
      pure (before /= after, labels')
    built === True
    -- Both are still there, whatever order the header bar puts them
    -- in.
    List.sort labels === ["fixed", "moving"]

-- | The label below this widget that says this, if there is one.
labelNamed :: Gtk.Widget -> Text -> IO (Maybe Gtk.Widget)
labelNamed root text = do
  widgets <- descendants root
  found   <- traverse matching widgets
  pure (listToMaybe (catMaybes found))
 where
  matching w = do
    said <- labelOf w
    pure (if said == text then Just w else Nothing)

tests :: IO Bool
tests = checkParallel $$(discover)
