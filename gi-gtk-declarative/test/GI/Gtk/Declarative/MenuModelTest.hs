{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for declarative menus.
--
-- A GTK 4 menu is a model of labels and action names rather than a tree
-- of widgets, so what these check is the actions: that activating one
-- emits the event the markup put there, and that patching the menu
-- keeps that true.
module GI.Gtk.Declarative.MenuModelTest where

import           Control.Concurrent.STM
import           Control.Exception.Safe         ( bracket )
import           Data.Text                      ( Text )
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.TestUtils

data MenuEvent = Open | Copy | Save
  deriving (Eq, Show)

firstMenu :: Widget MenuEvent
firstMenu = menuBar
  []
  [ subMenu "File" [menuSection Nothing [menuItem "Open" Open]]
  , subMenu "Edit" [menuItem "Copy" Copy]
  ]

secondMenu :: Widget MenuEvent
secondMenu = menuBar
  []
  [ subMenu "File" [menuSection Nothing [menuItem "Save" Save]]
  , subMenu "Edit" [menuItem "Copy" Copy]
  ]

prop_menu_items_emit_their_events = withTests 1 . property $ do
  (found, events) <- evalIO (activate [firstMenu] ["menu.item0", "menu.item1"])
  found === [True, True]
  events === [Open, Copy]

prop_patched_menu_emits_the_new_events = withTests 1 . property $ do
  (found, events) <- evalIO
    (activate [firstMenu, secondMenu] ["menu.item0", "menu.item1"])
  found === [True, True]
  events === [Save, Copy]

-- | Render the menus in turn, subscribe to the last one, activate the
-- named actions, and collect what came back.
activate :: [Widget MenuEvent] -> [Text] -> IO ([Bool], [MenuEvent])
activate []             _       = fail "activate: no markup to render"
activate (first : rest) actions = do
  received <- newTBQueueIO (fromIntegral (max 1 (length actions)))
  runUI $ bracket (Gtk.new Gtk.Window []) Gtk.windowDestroy $ \window -> do
    state <- create first
    setWindowChild window state
    (lastState, lastMarkup) <- foldPatches state first rest
    sub     <- subscribe lastMarkup lastState (atomically . writeTBQueue received)
    bar     <- someStateWidget lastState
    found   <- traverse
      (\action -> Gtk.widgetActivateAction bar action Nothing)
      actions
    cancel sub
    events <- atomically (flushTBQueue received)
    pure (found, events)
 where
  foldPatches state markup []             = pure (state, markup)
  foldPatches state markup (next : later) = do
    state' <- patch' state markup next
    foldPatches state' next later

-- * Test collection

tests :: IO Bool
tests = checkParallel $$(discover)
