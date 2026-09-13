{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE OverloadedLabels         #-}
{-# LANGUAGE OverloadedLists          #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE TemplateHaskell          #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for markup that cannot be patched into the markup that
-- follows it.
--
-- A property can be set and it can be changed, but it cannot be unset,
-- so markup that sets one and markup that does not are two different
-- widgets rather than one widget twice. Every kind of markup has that
-- branch, and each builds the widget again and hands back the new one.
--
-- What each test here reads is that the widget really is another
-- widget, that it shows what the new markup says, and that the one it
-- replaced is not left in the tree.
module GI.Gtk.Declarative.ReplaceTest where

import           Control.Concurrent.STM
import           Data.Text                      ( Text )
import           Data.Vector                    ( Vector )
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.MenuModel
import           GI.Gtk.Declarative.ModelView.ColumnView
                                                ( ColumnViewParams(..)
                                                , column
                                                , columnView
                                                , defaultColumnViewParams
                                                )
import qualified GI.Gtk.Declarative.ModelView.ColumnView
                                               as ColumnView
import           GI.Gtk.Declarative.ModelView.ListView
import qualified GI.Gtk.Declarative.ModelView.ListView
                                               as ListView
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.TestUtils

data Event = Toggled
  deriving (Eq, Show)

label :: Text -> Widget Event
label text = widget Gtk.Label [#label := text]

-- | Render the first markup, patch it with the second, and say whether
-- the widget that came out is another widget, along with what it
-- shows.
replacing :: Widget Event -> Widget Event -> IO (Bool, [Text])
replacing first second = do
  state  <- runUI (create first)
  before <- runUI (someStateWidget state)
  state' <- runUI (patch' state first second)
  after  <- runUI (someStateWidget state')
  labels <- runUI (descendantLabels after)
  pure (before /= after, labels)

-- * One widget at a time

prop_a_single_widget_that_cannot_be_patched_is_built_again =
  withTests 1 . property $ do
    (built, labels) <- evalIO $ replacing
      (widget Gtk.Label [#label := ("before" :: Text), #selectable := True])
      (widget Gtk.Label [#label := ("after" :: Text)])
    built === True
    labels === ["after"]

prop_a_bin_that_cannot_be_patched_is_built_again = withTests 1 . property $ do
  (built, labels) <- evalIO $ replacing
    (bin Gtk.Frame
         [#label := ("before" :: Text), #labelXalign := 1]
         (label "body")
    )
    (bin Gtk.Frame [#label := ("after" :: Text)] (label "body"))
  built === True
  -- A frame draws its own label as a widget of its own, so the new
  -- frame reads as the new label and the child it kept.
  labels === ["after", "body"]

prop_a_container_that_cannot_be_patched_is_built_again =
  withTests 1 . property $ do
    (built, labels) <- evalIO $ replacing
      (container Gtk.Box
                 [#spacing := 4, #homogeneous := True]
                 [BoxChild defaultBoxChildProperties (label "one")]
      )
      (container Gtk.Box
                 [#spacing := 4]
                 [BoxChild defaultBoxChildProperties (label "one")]
      )
    built === True
    labels === ["one"]

prop_a_menu_that_cannot_be_patched_is_built_again = withTests 1 . property $ do
  (built, _) <- evalIO $ replacing
    (menuBar [#name := ("bar" :: Text), #widthRequest := 20] items)
    (menuBar [#name := ("bar" :: Text)] items)
  built === True
  -- A menu bar holds submenus: an item at the top level of one is a
  -- warning from GTK rather than a menu.
  where items = [subMenu ("File" :: Text) [menuItem ("Quit" :: Text) Toggled]]

prop_a_list_view_that_cannot_be_patched_is_built_again =
  withTests 1 . property $ do
    (built, _) <- evalIO $ replacing
      (listView [#name := ("rows" :: Text), #showSeparators := True] rowParams)
      (listView [#name := ("rows" :: Text)] rowParams)
    built === True
  where
    rowParams :: ListViewParams Text Event
    rowParams =
      (defaultListViewParams label) { ListView.rows = ["one", "two"] }

prop_a_column_view_that_cannot_be_patched_is_built_again =
  withTests 1 . property $ do
    (built, _) <- evalIO $ replacing
      (columnView [#name := ("cells" :: Text), #showRowSeparators := True]
                  cellParams
      )
      (columnView [#name := ("cells" :: Text)] cellParams)
    built === True
  where
    cellParams :: ColumnViewParams Text Event
    cellParams =
      (defaultColumnViewParams [column "only" "Only" label])
        { ColumnView.rows = ["one", "two"]
        }

-- * A child, rather than the widget the markup starts with

-- | A child of a container that cannot be patched is built again and
-- put back where it was, rather than at the end.
prop_a_child_that_cannot_be_patched_keeps_its_place =
  withTests 1 . property $ do
    (_, labels) <- evalIO $ replacing
      (container
        Gtk.Box
        []
        [ BoxChild defaultBoxChildProperties (label "one")
        , BoxChild defaultBoxChildProperties
          (widget Gtk.Label [#label := ("two" :: Text), #selectable := True])
        , BoxChild defaultBoxChildProperties (label "three")
        ]
      )
      (container
        Gtk.Box
        []
        [ BoxChild defaultBoxChildProperties (label "one")
        , BoxChild defaultBoxChildProperties (label "TWO")
        , BoxChild defaultBoxChildProperties (label "three")
        ]
      )
    labels === ["one", "TWO", "three"]

-- | A widget that was built again emits, which says the subscription
-- that follows a patch reaches the new widget rather than the one it
-- replaced.
prop_a_widget_that_was_built_again_emits = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let clickable :: Vector (Attribute Gtk.ToggleButton Event) -> Widget Event
        clickable attributes = widget Gtk.ToggleButton attributes
        first  = clickable [#label := ("before" :: Text), on #toggled Toggled]
        second = clickable [on #toggled Toggled]
    state  <- runUI (create first)
    state' <- runUI (patch' state first second)
    button <- runUI (Gtk.unsafeCastTo Gtk.ToggleButton =<< someStateWidget state')
    sub    <- runUI (subscribe second state' (atomically . writeTBQueue received))
    runUI (Gtk.toggleButtonSetActive button True)
    runUI (cancel sub)
    atomically (flushTBQueue received)
  events === [Toggled]

tests :: IO Bool
tests = checkParallel $$(discover)
