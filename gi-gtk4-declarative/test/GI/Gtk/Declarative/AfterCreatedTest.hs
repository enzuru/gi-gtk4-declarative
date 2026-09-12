{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE OverloadedLabels         #-}
{-# LANGUAGE OverloadedLists          #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE RecordWildCards          #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE TemplateHaskell          #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for 'afterCreated'.
--
-- The contract is the whole of it: the action runs when the widget is
-- built, and a patch does not run it again. Each shape of widget in the
-- library has its own creation, so each is checked.
module GI.Gtk.Declarative.AfterCreatedTest where

import           Control.Exception.Safe         ( bracket )
import           Data.IORef
import           Data.Text                      ( Text )
import           Data.Vector                    ( Vector )
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.EventSource ( Subscription
                                                , fromCancellation
                                                )
import           GI.Gtk.Declarative.ModelView.ColumnView
                                                ( column
                                                , columnView
                                                , defaultColumnViewParams
                                                )
import qualified GI.Gtk.Declarative.ModelView.ColumnView
                                               as ColumnView
import           GI.Gtk.Declarative.ModelView.ListView
                                                ( defaultListViewParams
                                                , listView
                                                )
import qualified GI.Gtk.Declarative.ModelView.ListView
                                               as ListView
import           GI.Gtk.Declarative.State       ( someStateWidget )
import           GI.Gtk.Declarative.TestUtils

data Event = Event
  deriving (Eq, Show)

-- | Build the markup twice from the same counting action, render the
-- first, patch it with the second, and answer how often the action ran
-- after each step.
ranHowOften :: (IORef Int -> Widget Event) -> IO (Int, Int)
ranHowOften markupWith = do
  counter <- newIORef (0 :: Int)
  let first  = markupWith counter
      second = markupWith counter
  runUI $ bracket (Gtk.new Gtk.Window []) Gtk.windowDestroy $ \window -> do
    state <- create first
    Gtk.windowSetChild window . Just =<< someStateWidget state
    created <- readIORef counter
    _       <- patch' state first second
    patched <- readIORef counter
    pure (created, patched)

count :: IORef Int -> Attribute widget Event
count counter = afterCreated (\_widget -> modifyIORef' counter (+ 1))

prop_a_single_widget_runs_it_once = withTests 1 . property $ do
  (created, patched) <- evalIO $ ranHowOften
    (\counter -> widget Gtk.Label [#label := ("a" :: Text), count counter])
  created === 1
  patched === 1

prop_a_bin_runs_it_once = withTests 1 . property $ do
  (created, patched) <- evalIO $ ranHowOften
    (\counter ->
      bin Gtk.Frame [count counter] (widget Gtk.Label [#label := ("a" :: Text)])
    )
  created === 1
  patched === 1

prop_a_container_runs_it_once = withTests 1 . property $ do
  (created, patched) <- evalIO $ ranHowOften
    (\counter -> container
      Gtk.Box
      [count counter]
      [BoxChild defaultBoxChildProperties (widget Gtk.Label [#label := ("a" :: Text)])]
    )
  created === 1
  patched === 1

prop_a_custom_widget_runs_it_once = withTests 1 . property $ do
  (created, patched) <- evalIO $ ranHowOften counting
  created === 1
  patched === 1
 where
  counting counter = Widget (CustomWidget { .. })
   where
    customWidget     = Gtk.Label
    customParams     = ()
    customAttributes = [count counter]
    customCreate ()  = (\made -> (made, ())) <$> Gtk.new Gtk.Label []
    customPatch :: () -> () -> () -> CustomPatch Gtk.Label ()
    customPatch _ () () = CustomKeep
    customSubscribe
      :: () -> () -> Gtk.Label -> (Event -> IO ()) -> IO Subscription
    customSubscribe () () _label _cb = pure (fromCancellation (pure ()))

prop_a_list_view_runs_it_once = withTests 1 . property $ do
  (created, patched) <- evalIO $ ranHowOften
    (\counter -> listView
      [count counter]
      (defaultListViewParams (\text -> widget Gtk.Label [#label := text]))
        { ListView.rows = ["a", "b"] :: Vector Text
        }
    )
  created === 1
  patched === 1

prop_a_column_view_runs_it_once = withTests 1 . property $ do
  (created, patched) <- evalIO $ ranHowOften
    (\counter -> columnView
      [count counter]
      (defaultColumnViewParams
          [column "one" "One" (\text -> widget Gtk.Label [#label := text])]
        )
        { ColumnView.rows = ["a", "b"] :: Vector Text
        }
    )
  created === 1
  patched === 1

-- * Test collection

tests :: IO Bool
tests = checkParallel $$(discover)
