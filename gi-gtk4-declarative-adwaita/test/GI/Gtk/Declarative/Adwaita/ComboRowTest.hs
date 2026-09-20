{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for the combo row.
--
-- A combo row is the toggle group's question at a larger size, and it
-- has the same two traps: a row that drifts from what the markup says,
-- and a row that reports a choice the markup itself asked for.
module GI.Gtk.Declarative.Adwaita.ComboRowTest where

import           Control.Concurrent.STM
import           Data.Text                      ( Text )
import qualified GI.Adw                        as Adw
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Adwaita.ComboRow
import           GI.Gtk.Declarative.Adwaita.TestUtils
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.State

data Event = Chose Text
  deriving (Eq, Show)

-- | The row Stones asked for: a board size, named by the number of
-- lines and labelled the way a person reads it.
sized :: Maybe Text -> Widget Event
sized chosen' = comboRow
  [#title := ("Board" :: Text)]
  defaultComboRowParams { choices  = [ choice "9"  "9x9"
                                     , choice "13" "13x13"
                                     , choice "19" "19x19"
                                     ]
                        , chosen   = chosen'
                        , onChosen = Just Chose
                        }

-- | The same row with the smallest board taken away. The attributes
-- match the ones above: a markup that drops a property is a widget
-- built again rather than patched, and these tests are about patching.
fewer :: Maybe Text -> Widget Event
fewer chosen' = comboRow
  [#title := ("Board" :: Text)]
  defaultComboRowParams { choices  = [choice "13" "13x13", choice "19" "19x19"]
                        , chosen   = chosen'
                        , onChosen = Just Chose
                        }

-- | Render the markup and hand the row to the action.
withRow :: Widget Event -> (Adw.ComboRow -> IO a) -> IO a
withRow markup f = do
  state   <- runUI (create markup)
  widget' <- runUI (someStateWidget state)
  runUI (f =<< Gtk.unsafeCastTo Adw.ComboRow widget')

-- * The choices

prop_a_row_is_built_with_the_choices_it_was_given =
  withTests 1 . property $ do
    labels <- evalIO $ withRow (sized (Just "13")) choiceLabels
    labels === ["9x9", "13x13", "19x19"]

prop_the_named_choice_is_the_one_selected = withTests 1 . property $ do
  selected <- evalIO $ withRow (sized (Just "13")) Adw.comboRowGetSelected
  selected === 1

-- | A row with choices in it sits on one of them, whatever the markup
-- says. The selection model libadwaita builds picks the first one by
-- itself, and no part of @AdwComboRow@ asks it not to, so a markup
-- that names no choice leaves the row where the row put itself.
prop_a_markup_that_names_no_choice_leaves_the_row_alone =
  withTests 1 . property $ do
    selected <- evalIO $ withRow (sized Nothing) Adw.comboRowGetSelected
    selected === 0

-- | A name that is in no choice is the same case. The row keeps what
-- it has rather than emptying, because emptying is a thing this widget
-- cannot do.
prop_a_name_that_is_in_no_choice_leaves_the_row_alone =
  withTests 1 . property $ do
    selected <- evalIO $ withRow (sized (Just "21")) Adw.comboRowGetSelected
    selected === 0

-- | A row with no choices at all is the one row on nothing.
prop_a_row_with_no_choices_is_on_nothing = withTests 1 . property $ do
  selected <- evalIO $ withRow
    (comboRow [] defaultComboRowParams { onChosen = Just Chose } :: Widget Event
    )
    Adw.comboRowGetSelected
  selected === Gtk.INVALID_LIST_POSITION

-- | A label is what a person reads and a name is what the program
-- means, and this row is one where the two are never the same text.
prop_a_label_is_read_and_a_name_is_meant = withTests 1 . property $ do
  (labels, selected, events) <- evalIO $ do
    received <- newTBQueueIO 10
    let markup = sized (Just "19")
    state   <- runUI (create markup)
    widget' <- runUI (someStateWidget state)
    row     <- runUI (Gtk.unsafeCastTo Adw.ComboRow widget')
    sub <- runUI (subscribe markup state (atomically . writeTBQueue received))
    labels' <- runUI (choiceLabels row)
    -- What somebody choosing the first one does.
    runUI (Adw.comboRowSetSelected row 0)
    runUI (cancel sub)
    (,,) labels' <$> runUI (Adw.comboRowGetSelected row) <*> atomically
      (flushTBQueue received)
  labels === ["9x9", "13x13", "19x19"]
  selected === 0
  events === [Chose "9"]

-- * What a row reports

prop_choosing_another_reports_its_name = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let markup = sized (Just "9")
    state   <- runUI (create markup)
    widget' <- runUI (someStateWidget state)
    row     <- runUI (Gtk.unsafeCastTo Adw.ComboRow widget')
    sub <- runUI (subscribe markup state (atomically . writeTBQueue received))
    runUI (Adw.comboRowSetSelected row 2)
    runUI (cancel sub)
    atomically (flushTBQueue received)
  events === [Chose "19"]

-- | A choice the markup asked for is not news to the program that
-- asked for it.
prop_a_choice_the_markup_says_does_not_report = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let first  = sized (Just "9")
        second = sized (Just "19")
    state <- runUI (create first)
    sub   <- runUI (subscribe first state (atomically . writeTBQueue received))
    _     <- runUI (patch' state first second)
    runUI (cancel sub)
    atomically (flushTBQueue received)
  events === []

-- | A patch that sets what is already set changes nothing, so there is
-- no loop of a row reporting its own value back to the program.
prop_a_row_patched_with_the_same_choice_reports_nothing =
  withTests 1 . property $ do
    events <- evalIO $ do
      received <- newTBQueueIO 10
      let markup = sized (Just "13")
      state <- runUI (create markup)
      sub <- runUI (subscribe markup state (atomically . writeTBQueue received))
      _   <- runUI (patch' state markup markup)
      runUI (cancel sub)
      atomically (flushTBQueue received)
    events === []

-- | The reason this widget is here, as with the toggle group.
--
-- Somebody chooses, and the markup that follows says what it said
-- before. The value the markup declares has not changed, so a patch
-- that only looked at the markup would set nothing, and the row would
-- keep the choice the markup does not say.
prop_a_row_is_put_back_when_it_has_drifted = withTests 1 . property $ do
  (afterChoosing, afterPatch) <- evalIO $ do
    let markup = sized (Just "9")
    state   <- runUI (create markup)
    widget' <- runUI (someStateWidget state)
    row     <- runUI (Gtk.unsafeCastTo Adw.ComboRow widget')
    runUI (Adw.comboRowSetSelected row 2)
    afterChoosing' <- runUI (Adw.comboRowGetSelected row)
    _              <- runUI (patch' state markup markup)
    afterPatch'    <- runUI (Adw.comboRowGetSelected row)
    pure (afterChoosing', afterPatch')
  afterChoosing === 2
  afterPatch === 0

-- * Choices that change under the row

prop_new_choices_keep_the_choice_that_is_still_there =
  withTests 1 . property $ do
    (labels, selected) <- evalIO $ do
      let first  = sized (Just "13")
          second = fewer (Just "13")
      state   <- runUI (create first)
      state'  <- runUI (patch' state first second)
      widget' <- runUI (someStateWidget state')
      row     <- runUI (Gtk.unsafeCastTo Adw.ComboRow widget')
      runUI ((,) <$> choiceLabels row <*> Adw.comboRowGetSelected row)
    labels === ["13x13", "19x19"]
    selected === 0

-- | A name that the new choices do not have leaves the row on the
-- first of them, which is where libadwaita puts it. The program is the
-- one that knows what it means instead, and says so in the same
-- render.
prop_new_choices_leave_a_name_that_is_gone_on_the_first =
  withTests 1 . property $ do
    (labels, selected) <- evalIO $ do
      let first  = sized (Just "9")
          second = fewer (Just "9")
      state   <- runUI (create first)
      state'  <- runUI (patch' state first second)
      widget' <- runUI (someStateWidget state')
      row     <- runUI (Gtk.unsafeCastTo Adw.ComboRow widget')
      runUI ((,) <$> choiceLabels row <*> Adw.comboRowGetSelected row)
    labels === ["13x13", "19x19"]
    selected === 0

-- | Building a model changes what is selected, which is this library
-- talking to itself. A row that is handed new choices reports nothing
-- for them, and reports under the right name afterwards.
prop_a_row_reports_the_right_name_after_its_choices_changed =
  withTests 1 . property $ do
    events <- evalIO $ do
      received <- newTBQueueIO 10
      let first  = sized (Just "9")
          second = fewer (Just "19")
      state   <- runUI (create first)
      sub <- runUI (subscribe first state (atomically . writeTBQueue received))
      state'  <- runUI (patch' state first second)
      widget' <- runUI (someStateWidget state')
      row     <- runUI (Gtk.unsafeCastTo Adw.ComboRow widget')
      -- Somebody picks the first of the new choices.
      runUI (Adw.comboRowSetSelected row 0)
      runUI (cancel sub)
      atomically (flushTBQueue received)
    events === [Chose "13"]

-- | The handler is connected when the row is built rather than when it
-- is subscribed, so a row subscribed twice reports once.
prop_subscribing_twice_does_not_stack_handlers =
  withTests 1 . property $ do
    (first, second) <- evalIO $ do
      early <- newTBQueueIO 10
      late  <- newTBQueueIO 10
      let markup = sized (Just "9")
      state   <- runUI (create markup)
      widget' <- runUI (someStateWidget state)
      row     <- runUI (Gtk.unsafeCastTo Adw.ComboRow widget')
      early'  <- runUI (subscribe markup state (atomically . writeTBQueue early))
      late'   <- runUI (subscribe markup state (atomically . writeTBQueue late))
      runUI (Adw.comboRowSetSelected row 1)
      runUI (cancel early')
      runUI (cancel late')
      (,) <$> atomically (flushTBQueue early) <*> atomically (flushTBQueue late)
    first === []
    second === [Chose "13"]

-- * Reading the row back

-- | What the row offers, in the order it offers it.
choiceLabels :: Adw.ComboRow -> IO [Text]
choiceLabels row = do
  model <- Adw.comboRowGetModel row
  case model of
    Nothing    -> pure []
    Just found -> do
      strings <- Gtk.castTo Gtk.StringList found
      maybe (pure []) (go 0) strings
 where
  go position strings = do
    said <- Gtk.stringListGetString strings position
    case said of
      Nothing   -> pure []
      Just text -> (text :) <$> go (position + 1) strings

tests :: IO Bool
tests = checkParallel $$(discover)
