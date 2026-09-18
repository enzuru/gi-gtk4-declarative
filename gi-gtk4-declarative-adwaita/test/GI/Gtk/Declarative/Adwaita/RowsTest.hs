{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for the rows a settings page is made of, and for the toggle
-- group that goes in one.
module GI.Gtk.Declarative.Adwaita.RowsTest where

import           Control.Concurrent.STM
import           Data.Text                      ( Text )
import qualified Data.Vector                   as Vector
import qualified GI.Adw                        as Adw
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Adwaita.Rows
import           GI.Gtk.Declarative.Adwaita.TestUtils
import           GI.Gtk.Declarative.Adwaita.ToggleGroup
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.State

data Event = Chose Text
  deriving (Eq, Show)

label :: Text -> Widget Event
label text = widget Gtk.Label [#label := text]

-- | Render the first markup, patch it with the others in turn, and
-- hand the widget to the action.
render :: [Widget Event] -> (Gtk.Widget -> IO a) -> IO a
render []             _ = fail "render: no markup to render"
render (first : rest) f = do
  state  <- runUI (create first)
  state' <- step (state, first) rest
  runUI (f =<< someStateWidget state')
 where
  step (state, _  ) []           = pure state
  step (state, old) (new : more) = do
    patched <- runUI (patch' state old new)
    step (patched, new) more

-- * The preferences group

prop_a_preferences_group_holds_its_rows = withTests 1 . property $ do
  (labels, title) <- evalIO $ render
    [ container
        Adw.PreferencesGroup
        [#title := ("Board" :: Text)]
        [ widget Adw.SwitchRow [#title := ("Coordinates" :: Text)]
        , widget Adw.SpinRow [#title := ("Handicap" :: Text)]
        ]
    ]
    (\widget' -> do
      group  <- Gtk.unsafeCastTo Adw.PreferencesGroup widget'
      title' <- Adw.preferencesGroupGetTitle group
      rows   <- descendantTitles widget'
      pure (rows, title')
    )
  -- A switch row and a spin row are widgets with properties, and need
  -- nothing of their own from this package.
  labels === ["Coordinates", "Handicap"]
  title === "Board"

prop_a_preferences_group_takes_a_row_away = withTests 1 . property $ do
  rows <- evalIO $ render
    [ container
      Adw.PreferencesGroup
      []
      [ widget Adw.SwitchRow [#title := ("one" :: Text)]
      , widget Adw.SwitchRow [#title := ("two" :: Text)]
      ]
    , container Adw.PreferencesGroup
                []
                [widget Adw.SwitchRow [#title := ("one" :: Text)]]
    ]
    descendantTitles
  rows === ["one"]

prop_a_preferences_group_takes_a_header_suffix = withTests 1 . property $ do
  found <- evalIO $ render
    [ container Adw.PreferencesGroup
                [headerSuffix (label "beside the title")]
                []
    ]
    (\widget' -> do
      group <- Gtk.unsafeCastTo Adw.PreferencesGroup widget'
      traverse labelOf =<< Adw.preferencesGroupGetHeaderSuffix group
    )
  found === Just "beside the title"

-- * The action row

prop_an_action_row_holds_widgets_at_either_end = withTests 1 . property $ do
  labels <- evalIO $ render
    [ container Adw.ActionRow
                [#title := ("Size" :: Text)]
                [rowPrefix (label "before"), rowSuffix (label "after")]
    ]
    descendantLabels
  labels === ["before", "Size", "after"]

prop_an_action_row_child_that_changes_end_is_built_again =
  withTests 1 . property $ do
    built <- evalIO $ do
      let row children = container Adw.ActionRow [] children :: Widget Event
          atStart = row [rowPrefix (label "moving")]
          atEnd   = row [rowSuffix (label "moving")]
      state   <- runUI (create atStart)
      widget' <- runUI (someStateWidget state)
      before  <- runUI (labelNamed widget' "moving")
      _       <- runUI (patch' state atStart atEnd)
      after   <- runUI (labelNamed widget' "moving")
      pure (before /= after)
    built === True

-- * The page, the dialog and the expander row

prop_a_preferences_page_holds_its_groups = withTests 1 . property $ do
  titles <- evalIO $ render
    [ container
        Adw.PreferencesPage
        []
        [ container Adw.PreferencesGroup [#title := ("One" :: Text)] []
        , container Adw.PreferencesGroup [#title := ("Two" :: Text)] []
        ]
    ]
    groupTitles
  titles === ["One", "Two"]

prop_a_preferences_page_takes_a_group_away = withTests 1 . property $ do
  titles <- evalIO $ render
    [ container
      Adw.PreferencesPage
      []
      [ container Adw.PreferencesGroup [#title := ("One" :: Text)] []
      , container Adw.PreferencesGroup [#title := ("Two" :: Text)] []
      ]
    , container Adw.PreferencesPage
                []
                [container Adw.PreferencesGroup [#title := ("One" :: Text)] []]
    ]
    groupTitles
  titles === ["One"]

-- | A dialog's pages are not below it in the widget tree until it is
-- presented, so what says they arrived is the dialog itself: a dialog
-- with no pages shows none.
prop_a_preferences_dialog_holds_its_pages = withTests 1 . property $ do
  visible <- evalIO $ render
    [ container
        Adw.PreferencesDialog
        []
        [ container Adw.PreferencesPage [#name := ("first" :: Text)] []
        , container Adw.PreferencesPage [#name := ("second" :: Text)] []
        ]
    ]
    (\widget' -> do
      dialog <- Gtk.unsafeCastTo Adw.PreferencesDialog widget'
      Adw.preferencesDialogGetVisiblePageName dialog
    )
  visible === Just "first"

prop_an_expander_row_holds_the_rows_it_reveals = withTests 1 . property $ do
  titles <- evalIO $ render
    [ container
        Adw.ExpanderRow
        [#title := ("Nightlies" :: Text)]
        [ widget Adw.ActionRow [#title := ("Metadata URL" :: Text)]
        , widget Adw.SwitchRow [#title := ("Prereleases" :: Text)]
        ]
    ]
    descendantTitles
  -- The expander row is a row itself, and libadwaita puts a row of its
  -- own inside it for the header, so the title is read twice before
  -- the rows it reveals.
  titles === ["Nightlies", "Nightlies", "Metadata URL", "Prereleases"]

-- | The row this item was reported against: a container, and a thing a
-- person changes. Its header switch has to be held, and a container
-- that dropped `holding` is what the report was about.
prop_an_expander_row_is_held_to_its_switch = withTests 1 . property $ do
  (drifted, afterPatch) <- evalIO $ do
    let markup =
          container Adw.ExpanderRow
                    [#showEnableSwitch := True, holding #enableExpansion True]
                    [widget Adw.ActionRow [#title := ("Inside" :: Text)]]
            :: Widget Event
    state    <- runUI (create markup)
    widget'  <- runUI (someStateWidget state)
    row      <- runUI (Gtk.unsafeCastTo Adw.ExpanderRow widget')
    runUI (Adw.expanderRowSetEnableExpansion row False)
    drifted' <- runUI (Adw.expanderRowGetEnableExpansion row)
    _        <- runUI (patch' state markup markup)
    after    <- runUI (Adw.expanderRowGetEnableExpansion row)
    pure (drifted', after)
  drifted === False
  afterPatch === True

-- | The titles of the preferences groups below a widget.
groupTitles :: Gtk.Widget -> IO [Text]
groupTitles root = do
  widgets <- descendants root
  groups  <- traverse (Gtk.castTo Adw.PreferencesGroup) widgets
  traverse Adw.preferencesGroupGetTitle (catMaybes groups)

catMaybes :: [Maybe a] -> [a]
catMaybes = foldr (\x xs -> maybe xs (: xs) x) []

-- * The toggle group

sizes :: [Toggle]
sizes = [toggle "9" "9x9", toggle "13" "13x13", toggle "19" "19x19"]

sized :: Maybe Text -> Widget Event
sized chosen = toggleGroup
  []
  defaultToggleGroupParams { toggles     = Vector.fromList sizes
                           , active      = chosen
                           , onActivated = Just Chose
                           }

prop_a_toggle_group_holds_its_toggles = withTests 1 . property $ do
  (count, labels, chosen) <- evalIO $ render
    [sized (Just "13")]
    (\widget' -> do
      group  <- Gtk.unsafeCastTo Adw.ToggleGroup widget'
      count' <- Adw.toggleGroupGetNToggles group
      labels' <- toggleLabels group
      chosen' <- Adw.toggleGroupGetActiveName group
      pure (count', labels', chosen')
    )
  count === 3
  labels === [Just "9x9", Just "13x13", Just "19x19"]
  chosen === Just "13"

prop_a_toggle_group_follows_the_markup = withTests 1 . property $ do
  chosen <- evalIO $ render
    [sized (Just "9"), sized (Just "19")]
    (\widget' -> do
      group <- Gtk.unsafeCastTo Adw.ToggleGroup widget'
      Adw.toggleGroupGetActiveName group
    )
  chosen === Just "19"

-- | The reason this widget is here.
--
-- Somebody chooses a toggle, and the markup that follows says what it
-- said before. The value the markup declares has not changed, so a
-- patch that only looked at the markup would set nothing, and the
-- group would keep the choice the markup does not say. This one reads
-- the group before it writes to it.
prop_a_toggle_group_is_put_back_when_it_has_drifted =
  withTests 1 . property $ do
    (afterClick, afterPatch) <- evalIO $ do
      let markup = sized (Just "9")
      state   <- runUI (create markup)
      widget' <- runUI (someStateWidget state)
      group   <- runUI (Gtk.unsafeCastTo Adw.ToggleGroup widget')
      -- What a click does.
      runUI (Adw.toggleGroupSetActiveName group (Just "19"))
      afterClick' <- runUI (Adw.toggleGroupGetActiveName group)
      -- The same markup again, which is what an update that ignored
      -- the choice renders.
      _           <- runUI (patch' state markup markup)
      afterPatch' <- runUI (Adw.toggleGroupGetActiveName group)
      pure (afterClick', afterPatch')
    afterClick === Just "19"
    afterPatch === Just "9"

prop_a_toggle_group_emits_what_somebody_chose = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let markup = sized (Just "9")
    state   <- runUI (create markup)
    widget' <- runUI (someStateWidget state)
    group   <- runUI (Gtk.unsafeCastTo Adw.ToggleGroup widget')
    sub     <- runUI (subscribe markup state (atomically . writeTBQueue received))
    runUI (Adw.toggleGroupSetActiveName group (Just "13"))
    runUI (cancel sub)
    atomically (flushTBQueue received)
  events === [Chose "13"]

-- | A choice the markup asked for is not news to the program that
-- asked for it.
prop_a_toggle_group_does_not_emit_what_the_markup_says =
  withTests 1 . property $ do
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

prop_a_toggle_group_takes_new_toggles = withTests 1 . property $ do
  (labels, chosen) <- evalIO $ do
    let first = sized (Just "13")
        second = toggleGroup
          []
          defaultToggleGroupParams
            { toggles     = [toggle "13" "13x13", toggle "19" "19x19"]
            , active      = Just "13"
            , onActivated = Just Chose
            } :: Widget Event
    state   <- runUI (create first)
    _       <- runUI (patch' state first second)
    widget' <- runUI (someStateWidget state)
    group   <- runUI (Gtk.unsafeCastTo Adw.ToggleGroup widget')
    runUI ((,) <$> toggleLabels group <*> Adw.toggleGroupGetActiveName group)
  labels === [Just "13x13", Just "19x19"]
  chosen === Just "13"

-- * Reading the widgets back

toggleLabels :: Adw.ToggleGroup -> IO [Maybe Text]
toggleLabels group = do
  count <- Adw.toggleGroupGetNToggles group
  traverse each [0 .. count - 1]
 where
  each index = do
    found <- Adw.toggleGroupGetToggle group index
    maybe (pure Nothing) Adw.toggleGetLabel found

-- | The titles of the rows below a widget.
descendantTitles :: Gtk.Widget -> IO [Text]
descendantTitles root = do
  widgets <- descendants root
  rows    <- traverse (Gtk.castTo Adw.PreferencesRow) widgets
  traverse Adw.preferencesRowGetTitle (catMaybes rows)

-- | The label below this widget that says this, if there is one.
labelNamed :: Gtk.Widget -> Text -> IO (Maybe Gtk.Widget)
labelNamed root text = do
  widgets <- descendants root
  go widgets
 where
  go []       = pure Nothing
  go (w : ws) = do
    said <- labelOf w
    if said == text then pure (Just w) else go ws

tests :: IO Bool
tests = checkParallel $$(discover)
