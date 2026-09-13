{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for the containers, one by one.
--
-- GTK 4 gives every container its own way of adding, replacing, and
-- removing children, so each one is checked against the widget tree it
-- actually builds: the children that are there, in the order they are
-- there, after a render and after patches that add, replace, and
-- remove.
module GI.Gtk.Declarative.ContainerTest where

import           Control.Concurrent.STM
import           Data.Maybe                     ( catMaybes
                                                , listToMaybe
                                                , mapMaybe
                                                )
import           Data.Text                      ( Text )
import           Data.Traversable               ( for )
import qualified Data.Vector                   as Vector
import qualified GI.Gsk                        as Gsk
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Container.ActionBar
import           GI.Gtk.Declarative.Container.Class
                                                ( childWidgets )
import           GI.Gtk.Declarative.Container.Fixed
import           GI.Gtk.Declarative.Container.Grid
import           GI.Gtk.Declarative.Container.HeaderBar
import           GI.Gtk.Declarative.Container.Stack
import           Data.Void                      ( vacuous )
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.State       ( someStateWidget )
import           GI.Gtk.Declarative.TestUtils
import           GI.Gtk.Declarative.TestWidget  ( TestWidget(..)
                                                , toTestWidget
                                                )

-- * Markup helpers

-- | What the buttons in these tests emit.
data Event = Toggled
  deriving (Eq, Show)

label :: Text -> Widget ()
label t = widget Gtk.Label [#label := t]

button :: Text -> Widget ()
button t = widget Gtk.Button [#label := t]

boxChild :: Widget () -> BoxChild ()
boxChild = BoxChild defaultBoxChildProperties

boxOf :: [Widget ()] -> Widget ()
boxOf children =
  container Gtk.Box [] (Vector.fromList (map boxChild children))

once :: PropertyT IO () -> Property
once = withTests 1 . property

-- * Box

prop_box_children_are_added_and_removed = once $ do
  after <- evalIO $ renderAll
    [boxOf [label "a", label "b", label "c"], boxOf [label "a", label "c"]]
    childLabels
  after === ["a", "c"]

prop_box_replaced_child_keeps_its_place = once $ do
  -- A label replacing a button is a replacement rather than a
  -- modification, which is what puts 'replaceChild' to work.
  after <- evalIO $ renderAll
    [ boxOf [label "a", button "b", label "c"]
    , boxOf [label "a", label "B", label "c"]
    ]
    childLabels
  after === ["a", "B", "c"]

prop_box_child_properties_are_applied = once $ do
  (expand, align, margin) <- evalIO $ renderAll
    [ container
        Gtk.Box
        [#orientation := Gtk.OrientationVertical]
        [ BoxChild
            defaultBoxChildProperties { expand  = True
                                      , fill    = True
                                      , padding = 7
                                      }
            (label "a")
        ]
    ]
    (\w -> do
      Just child <- Gtk.widgetGetFirstChild w
      (,,)
        <$> Gtk.widgetGetVexpand child
        <*> Gtk.widgetGetValign child
        <*> Gtk.widgetGetMarginTop child
    )
  expand === True
  align === Gtk.AlignFill
  margin === 7

-- | A box decides what its children's properties mean: its
-- orientation says which way `fill` and `padding` face. So a box that
-- turns from vertical to horizontal has to place its children again.
prop_box_children_follow_the_orientation = once $ do
  (align, margin) <- evalIO $ renderAll
    [ container
      Gtk.Box
      [#orientation := Gtk.OrientationVertical]
      [ BoxChild defaultBoxChildProperties { fill = False, padding = 5 }
                 (label "a")
      ]
    , container
      Gtk.Box
      [#orientation := Gtk.OrientationHorizontal]
      [ BoxChild defaultBoxChildProperties { fill = False, padding = 5 }
                 (label "a")
      ]
    ]
    (\w -> do
      Just child <- Gtk.widgetGetFirstChild w
      (,) <$> Gtk.widgetGetHalign child <*> Gtk.widgetGetMarginStart child
    )
  -- Along the new orientation, not the old one.
  align === Gtk.AlignCenter
  margin === 5

-- | A child whose own patch says to keep it as it is still has its
-- child properties applied again, because the container around it may
-- have changed in a way that changes what they mean.
--
-- A custom widget is what says to keep it: an ordinary widget is
-- patched, and this branch is for a child that is not.
prop_a_child_that_is_kept_still_follows_the_orientation = once $ do
  (align, margin) <- evalIO $ renderAll
    [ boxOf Gtk.OrientationVertical
    , boxOf Gtk.OrientationHorizontal
    ]
    (\w -> do
      Just child <- Gtk.widgetGetFirstChild w
      (,) <$> Gtk.widgetGetHalign child <*> Gtk.widgetGetMarginStart child
    )
  align === Gtk.AlignCenter
  margin === 5
 where
  boxOf orientation = container
    Gtk.Box
    [#orientation := orientation]
    [ BoxChild defaultBoxChildProperties { fill = False, padding = 5 }
               (vacuous (toTestWidget (TestCustomWidget (Just "type here"))))
    ]

-- | Markup that does not match the state it is patched against.
--
-- The library holds the widgets of a render beside the markup they
-- were built from, and every patch is given the markup of the render
-- before. A caller that hands it markup from some other render is out
-- of step, and these are the branches that put the container back in
-- order: widgets with no markup are taken off, and markup with no
-- widget is built.
prop_a_container_puts_itself_in_order_when_the_markup_is_out_of_step =
  once $ do
    (grown, shrunk, strays) <- evalIO $ do
      -- Three widgets, told that there was one, and asked for three.
      grown'  <- outOfStep (boxOf ["a", "b", "c"])
                           (boxOf ["a"])
                           (boxOf ["one", "two", "three"])
      -- One widget, told that there were three, and asked for one.
      shrunk' <- outOfStep (boxOf ["a"])
                           (boxOf ["a", "b", "c"])
                           (boxOf ["one"])
      -- Three widgets, told that there was one, and asked for one.
      strays' <- outOfStep (boxOf ["a", "b", "c"])
                           (boxOf ["a"])
                           (boxOf ["one"])
      pure (grown', shrunk', strays')
    grown === ["one", "two", "three"]
    shrunk === ["one"]
    strays === ["one"]
 where
  boxOf :: [Text] -> Widget ()
  boxOf ts = container
    Gtk.Box
    []
    (Vector.fromList [ BoxChild defaultBoxChildProperties (label t) | t <- ts ])
  outOfStep
    :: Widget () -> Widget () -> Widget () -> IO (Vector.Vector Text)
  outOfStep built old new = do
    state  <- runUI (create built)
    state' <- runUI (patch' state old new)
    runUI (childLabels =<< someStateWidget state')

-- * Grid

prop_grid_children_keep_their_positions = once $ do
  positions <- evalIO $ renderAll
    [ container
        Gtk.Grid
        []
        [ GridChild defaultGridChildProperties { leftAttach = 0
                                               , topAttach  = 0
                                               }
                    (label "a")
        , GridChild defaultGridChildProperties { leftAttach = 2
                                               , topAttach  = 1
                                               , width      = 3
                                               , height     = 2
                                               }
                    (label "b")
        ]
    ]
    (\w -> do
      Just grid <- Gtk.castTo Gtk.Grid w
      children  <- childWidgets grid
      for children $ \child -> do
        (column, row, width', height') <- Gtk.gridQueryChild grid child
        text                           <- labelOf child
        pure (text, column, row, width', height')
    )
  positions === [("a", 0, 0, 1, 1), ("b", 2, 1, 3, 2)]

-- * ListBox

prop_list_box_rows_are_patched = once $ do
  after <- evalIO $ renderAll
    [listBoxOf ["a", "b", "c"], listBoxOf ["a", "x"]]
    nestedChildLabels
  after === ["a", "x"]
 where
  listBoxOf ts = container
    Gtk.ListBox
    []
    (Vector.fromList [ bin Gtk.ListBoxRow [] (label t) | t <- ts ])

-- | A list box takes a child that is not a row, which GTK wraps in one.
-- What matters is the other end: removing such a child has to take the
-- wrapper with it, or the list keeps rows that show nothing.
prop_list_box_takes_widgets_that_are_not_rows = once $ do
  (labels, rowCount) <- evalIO $ renderAll
    [plainListBox ["a", "b", "c"], plainListBox ["a", "b"]]
    (\w -> do
      labels'   <- nestedChildLabels w
      children' <- childWidgets w
      pure (labels', length children')
    )
  labels === ["a", "b"]
  rowCount === 2
 where
  plainListBox ts =
    container Gtk.ListBox [] (Vector.fromList [ label t | t <- ts ])

-- * FlowBox

prop_flow_box_children_are_patched = once $ do
  after <- evalIO $ renderAll
    [flowBoxOf ["a", "b"], flowBoxOf ["a", "b", "c"]]
    nestedChildLabels
  after === ["a", "b", "c"]
 where
  flowBoxOf ts = container
    Gtk.FlowBox
    []
    (Vector.fromList [ bin Gtk.FlowBoxChild [] (label t) | t <- ts ])

-- * Paned

prop_paned_has_a_start_and_an_end_child = once $ do
  (start, end) <- evalIO $ renderAll
    [ paned [] (pane defaultPaneProperties (label "left"))
               (pane defaultPaneProperties (label "right"))
    , paned [] (pane defaultPaneProperties (label "left"))
               (pane defaultPaneProperties (button "right"))
    ]
    (\w -> do
      Just paned' <- Gtk.castTo Gtk.Paned w
      start'      <- Gtk.panedGetStartChild paned'
      end'        <- Gtk.panedGetEndChild paned'
      (,) <$> traverse labelOf start' <*> traverse labelOf end'
    )
  start === Just "left"
  end === Just "right"

-- * Notebook

prop_notebook_pages_and_tabs_are_patched = once $ do
  pages <- evalIO $ renderAll
    [ notebook [] [page "one" (label "first"), page "two" (label "second")]
    , notebook [] [page "one" (label "first"), page "TWO" (label "second")]
    ]
    (\w -> do
      Just notebook' <- Gtk.castTo Gtk.Notebook w
      count          <- Gtk.notebookGetNPages notebook'
      for (Vector.fromList [0 .. count - 1]) $ \i -> do
        Just content <- Gtk.notebookGetNthPage notebook' i
        tab          <- Gtk.notebookGetTabLabel notebook' content
        tabText      <- maybe (pure "") labelOf tab
        contentText  <- labelOf content
        pure (tabText, contentText)
    )
  pages === [("one", "first"), ("TWO", "second")]

-- | Pages are added, replaced and taken away, each with the tab label
-- that goes with it. A notebook holds the tab label of a page beside
-- the page rather than inside it, so taking a page away is two
-- removals rather than one.
prop_notebook_pages_are_added_and_taken_away = once $ do
  (grown, shrunk) <- evalIO $ do
    grown' <- renderAll
      [ notebook [] [page "one" (label "first")]
      , notebook
        []
        [ page "one" (label "first")
        , page "two" (label "second")
        , page "three" (label "third")
        ]
      ]
      notebookPages
    shrunk' <- renderAll
      [ notebook
        []
        [ page "one" (label "first")
        , page "two" (label "second")
        , page "three" (label "third")
        ]
      , notebook [] [page "one" (label "first")]
      ]
      notebookPages
    pure (grown', shrunk')
  grown === [("one", "first"), ("two", "second"), ("three", "third")]
  shrunk === [("one", "first")]

-- | A page whose widget is of another kind is built again and put back
-- in its place, with its tab.
prop_a_notebook_page_that_is_replaced_keeps_its_place = once $ do
  pages <- evalIO $ renderAll
    [ notebook
      []
      [page "one" (label "first"), page "two" (label "second")]
    , notebook
      []
      [ page "one" (label "first")
      , page "two" (widget Gtk.Button [#label := ("a button" :: Text)])
      ]
    ]
    notebookPages
  pages === [("one", "first"), ("two", "a button")]

-- | A tab that is a widget of its own rather than a title.
prop_a_notebook_takes_a_tab_of_its_own = once $ do
  pages <- evalIO $ renderAll
    [ notebook
        []
        [ pageWithTab (widget Gtk.Button [#label := ("the tab" :: Text)])
                      (label "first")
        ]
    ]
    notebookPages
  pages === [("the tab", "first")]

-- | The tab and the content of every page, in order.
notebookPages :: Gtk.Widget -> IO (Vector.Vector (Text, Text))
notebookPages w = do
  Just notebook' <- Gtk.castTo Gtk.Notebook w
  count          <- Gtk.notebookGetNPages notebook'
  for (Vector.fromList [0 .. count - 1]) $ \i -> do
    Just content <- Gtk.notebookGetNthPage notebook' i
    tab          <- Gtk.notebookGetTabLabel notebook' content
    tabText      <- maybe (pure "") labelOf tab
    contentText  <- labelOf content
    pure (tabText, contentText)

-- * Stack

prop_stack_children_are_named = once $ do
  (names, visible) <- evalIO $ renderAll
    [ container
        Gtk.Stack
        [#visibleChildName := ("second" :: Text)]
        [ StackChild defaultStackChildProperties { name  = "first"
                                                 , title = Just "First"
                                                 }
                     (label "one")
        , StackChild defaultStackChildProperties { name = "second" }
                     (label "two")
        ]
    ]
    (\w -> do
      Just stack <- Gtk.castTo Gtk.Stack w
      children   <- childWidgets stack
      names'     <- for children $ \child -> do
        page' <- Gtk.stackGetPage stack child
        Gtk.stackPageGetName page'
      visible' <- Gtk.stackGetVisibleChildName stack
      pure (names', visible')
    )
  names === [Just "first", Just "second"]
  visible === Just "second"

-- * HeaderBar

prop_header_bar_packs_start_title_and_end = once $ do
  (labels, title) <- evalIO $ renderAll
    [ container
        Gtk.HeaderBar
        []
        [ headerBarStart (button "back")
        , headerBarEnd (button "menu")
        , headerBarTitle (label "the title")
        ]
    ]
    (\w -> do
      Just bar <- Gtk.castTo Gtk.HeaderBar w
      title'   <- Gtk.headerBarGetTitleWidget bar
      (,) <$> descendantLabels bar <*> traverse labelOf title'
    )
  labels === ["back", "the title", "menu"]
  title === Just "the title"

-- * CenterBox

prop_center_box_fills_its_three_slots = once $ do
  slots <- evalIO $ renderAll
    [centerBox [] (label "start") (label "center") (label "end")]
    (\w -> do
      Just box <- Gtk.castTo Gtk.CenterBox w
      start    <- Gtk.centerBoxGetStartWidget box
      center   <- Gtk.centerBoxGetCenterWidget box
      end      <- Gtk.centerBoxGetEndWidget box
      (,,)
        <$> traverse labelOf start
        <*> traverse labelOf center
        <*> traverse labelOf end
    )
  slots === (Just "start", Just "center", Just "end")

-- * ActionBar

prop_action_bar_packs_start_center_and_end = once $ do
  (labels, center) <- evalIO $ renderAll
    [ container
        Gtk.ActionBar
        []
        [ actionBarStart (button "left")
        , actionBarEnd (button "right")
        , actionBarCenter (label "middle")
        ]
    ]
    (\w -> do
      Just bar <- Gtk.castTo Gtk.ActionBar w
      center'  <- Gtk.actionBarGetCenterWidget bar
      (,) <$> descendantLabels bar <*> traverse labelOf center'
    )
  labels === ["left", "middle", "right"]
  center === Just "middle"

-- * Fixed

prop_fixed_children_are_placed = once $ do
  positions <- evalIO $ renderAll
    [ container
      Gtk.Fixed
      []
      [ FixedChild (FixedChildProperties 10 20) (label "a")
      , FixedChild (FixedChildProperties 30 40) (label "b")
      ]
    , container
      Gtk.Fixed
      []
      [ FixedChild (FixedChildProperties 10 20) (label "a")
      , FixedChild (FixedChildProperties 50 60) (label "b")
      ]
    ]
    (\w -> do
      Just fixed <- Gtk.castTo Gtk.Fixed w
      children   <- childWidgets fixed
      for children $ \child -> do
        -- The position is read back through the child's transform.
        -- gtk_fixed_get_child_position answers 0 through the current
        -- bindings, whatever the child was put at.
        transform <- Gtk.fixedGetChildTransform fixed child
        (x', y')  <- maybe (pure (0, 0)) Gsk.transformToTranslate transform
        text      <- labelOf child
        pure (text, x', y')
    )
  positions === [("a", 10, 20), ("b", 50, 60)]

-- * Overlay

prop_overlay_has_a_main_child_and_overlays = once $ do
  (main', labels) <- evalIO $ renderAll
    [ container Gtk.Overlay
                []
                (Vector.fromList [label "below", label "above"])
    ]
    (\w -> do
      Just overlay <- Gtk.castTo Gtk.Overlay w
      child        <- Gtk.overlayGetChild overlay
      (,) <$> traverse labelOf child <*> descendantLabels overlay
    )
  main' === Just "below"
  labels === ["below", "above"]

-- | An overlay that is no longer named is taken off, and one that is
-- new is put on top.
prop_overlays_are_added_and_taken_away = once $ do
  (grown, shrunk) <- evalIO $ do
    grown' <- renderAll
      [ container Gtk.Overlay [] (Vector.fromList [label "below"])
      , container Gtk.Overlay
                  []
                  (Vector.fromList [label "below", label "above"])
      ]
      descendantLabels
    shrunk' <- renderAll
      [ container Gtk.Overlay
                  []
                  (Vector.fromList [label "below", label "above"])
      , container Gtk.Overlay [] (Vector.fromList [label "below"])
      ]
      descendantLabels
    pure (grown', shrunk')
  grown === ["below", "above"]
  shrunk === ["below"]

-- | The widget in a slot of a centre box that cannot be patched is
-- built again and put back in the same slot.
prop_center_box_slots_are_replaced = once $ do
  slots <- evalIO $ renderAll
    [ centerBox [] (label "start") (label "center") (label "end")
    , centerBox [] (button "start") (label "middle") (label "end")
    ]
    (\w -> do
      Just box <- Gtk.castTo Gtk.CenterBox w
      start    <- Gtk.centerBoxGetStartWidget box
      center   <- Gtk.centerBoxGetCenterWidget box
      end      <- Gtk.centerBoxGetEndWidget box
      (,,)
        <$> traverse labelOf start
        <*> traverse labelOf center
        <*> traverse labelOf end
    )
  slots === (Just "start", Just "middle", Just "end")

-- | A widget an action bar no longer names is taken off it, whichever
-- end it was at.
prop_action_bar_children_are_taken_away = once $ do
  (labels, center) <- evalIO $ renderAll
    [ container
      Gtk.ActionBar
      []
      [ actionBarStart (button "left")
      , actionBarEnd (button "right")
      , actionBarCenter (label "middle")
      ]
    , container Gtk.ActionBar [] [actionBarStart (button "left")]
    ]
    (\w -> do
      Just bar <- Gtk.castTo Gtk.ActionBar w
      center'  <- Gtk.actionBarGetCenterWidget bar
      (,) <$> descendantLabels bar <*> traverse labelOf center'
    )
  labels === ["left"]
  center === Nothing

-- | A page of a stack that is no longer named is taken away, and one
-- that is new is added under its own name.
prop_stack_children_are_added_and_taken_away = once $ do
  (grown, shrunk) <- evalIO $ do
    let stackOf names = container
          Gtk.Stack
          []
          (Vector.fromList
            [ StackChild defaultStackChildProperties { name = n } (label n)
            | n <- names
            ]
          )
        namesOf w = do
          Just stack <- Gtk.castTo Gtk.Stack w
          children   <- childWidgets stack
          for children $ \child -> do
            page' <- Gtk.stackGetPage stack child
            Gtk.stackPageGetName page'
    grown'  <- renderAll [stackOf ["one"], stackOf ["one", "two"]] namesOf
    shrunk' <- renderAll [stackOf ["one", "two"], stackOf ["one"]] namesOf
    pure (grown', shrunk')
  grown === [Just "one", Just "two"]
  shrunk === [Just "one"]

-- | A child a flow box no longer names is taken away.
prop_flow_box_children_are_taken_away = once $ do
  after <- evalIO $ renderAll
    [flowBoxOf ["a", "b", "c"], flowBoxOf ["a"]]
    nestedChildLabels
  after === ["a"]
 where
  flowBoxOf ts = container
    Gtk.FlowBox
    []
    (Vector.fromList [ bin Gtk.FlowBoxChild [] (label t) | t <- ts ])

-- | A child that changes which end of an action bar it is at is built
-- again, because where a child is packed is not something a patch can
-- change.
prop_an_action_bar_child_that_changes_end_is_built_again = once $ do
  (built, labels) <- evalIO $ do
    let bar children = container Gtk.ActionBar [] children :: Widget ()
        atStart = bar [actionBarStart (label "moving")]
        atEnd   = bar [actionBarEnd (label "moving")]
    state   <- runUI (create atStart)
    widget' <- runUI (someStateWidget state)
    before  <- runUI (labelNamed widget' "moving")
    _       <- runUI (patch' state atStart atEnd)
    after   <- runUI (labelNamed widget' "moving")
    labels' <- runUI (descendantLabels widget')
    pure (before /= after, labels')
  built === True
  labels === ["moving"]

-- | A page of a stack that is given another name is built again under
-- it, rather than kept under the old one.
prop_a_stack_child_that_is_renamed_is_built_again = once $ do
  (built, names) <- evalIO $ do
    let stackOf n = container
          Gtk.Stack
          []
          [StackChild defaultStackChildProperties { name = n } (label "page")]
          :: Widget ()
    state   <- runUI (create (stackOf "before"))
    widget' <- runUI (someStateWidget state)
    first   <- runUI (labelNamed widget' "page")
    _       <- runUI (patch' state (stackOf "before") (stackOf "after"))
    second  <- runUI (labelNamed widget' "page")
    names'  <- runUI $ do
      stack    <- Gtk.unsafeCastTo Gtk.Stack widget'
      children <- childWidgets stack
      for children $ \child -> do
        page' <- Gtk.stackGetPage stack child
        Gtk.stackPageGetName page'
    pure (first /= second, names')
  built === True
  names === [Just "after"]

-- | A child of a flow box that cannot be patched is built again and
-- put back at its own position.
prop_a_flow_box_child_that_is_replaced_keeps_its_place = once $ do
  after <- evalIO $ renderAll
    [ container
      Gtk.FlowBox
      []
      (Vector.fromList
        [ bin Gtk.FlowBoxChild [] (label "a")
        , bin Gtk.FlowBoxChild [#name := ("b" :: Text)] (label "b")
        , bin Gtk.FlowBoxChild [] (label "c")
        ]
      )
    , container
      Gtk.FlowBox
      []
      (Vector.fromList
        [ bin Gtk.FlowBoxChild [] (label "a")
        , bin Gtk.FlowBoxChild [] (label "B")
        , bin Gtk.FlowBoxChild [] (label "c")
        ]
      )
    ]
    nestedChildLabels
  after === ["a", "B", "c"]

-- | The main child of an overlay and the widgets on top of it are each
-- built again where they are.
prop_overlay_children_that_are_replaced_keep_their_places = once $ do
  (main', labels) <- evalIO $ renderAll
    [ container
      Gtk.Overlay
      []
      (Vector.fromList
        [ widget Gtk.Label [#label := ("below" :: Text), #selectable := True]
        , widget Gtk.Label [#label := ("above" :: Text), #selectable := True]
        ]
      )
    , container Gtk.Overlay
                []
                (Vector.fromList [label "BELOW", label "ABOVE"])
    ]
    (\w -> do
      Just overlay <- Gtk.castTo Gtk.Overlay w
      child        <- Gtk.overlayGetChild overlay
      (,) <$> traverse labelOf child <*> descendantLabels overlay
    )
  main' === Just "BELOW"
  labels === ["BELOW", "ABOVE"]

-- | A widget inside an action bar and a widget inside a stack emit
-- like any other, which says their child types are subscribed to
-- rather than only rendered.
prop_children_of_the_positional_containers_emit = once $ do
  (fromBar, fromStack) <- evalIO $ do
    fromBar'   <- emitting
      (container Gtk.ActionBar [] [actionBarStart (toggle "in the bar")])
    fromStack' <- emitting
      (container
        Gtk.Stack
        []
        [ StackChild defaultStackChildProperties { name = "one" }
                     (toggle "in the stack")
        ]
      )
    pure (fromBar', fromStack')
  fromBar === [Toggled]
  fromStack === [Toggled]
 where
  toggle text =
    widget Gtk.ToggleButton [#label := text, on #toggled Toggled] :: Widget Event

-- | Render markup, press the first toggle button in it, and say what
-- came out.
emitting :: Widget Event -> IO [Event]
emitting markup = do
  received <- newTBQueueIO 10
  state    <- runUI (create markup)
  widget'  <- runUI (someStateWidget state)
  sub      <- runUI (subscribe markup state (atomically . writeTBQueue received))
  runUI $ do
    widgets <- descendants widget'
    buttons <- traverse (Gtk.castTo Gtk.ToggleButton) widgets
    case mapMaybe id buttons of
      (button : _) -> Gtk.toggleButtonSetActive button True
      []           -> fail "no button in the markup"
  runUI (cancel sub)
  atomically (flushTBQueue received)

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

-- * Bins

prop_bin_child_is_replaced = once $ do
  after <- evalIO $ renderAll
    [ bin Gtk.Frame [] (label "first")
    , bin Gtk.Frame [] (button "second")
    ]
    (\w -> do
      Just frame <- Gtk.castTo Gtk.Frame w
      child      <- Gtk.frameGetChild frame
      traverse labelOf child
    )
  after === Just "second"

-- * Test collection

-- | A box takes a widget that is not a 'BoxChild', and wraps it in one
-- with the usual properties. That is the whole of
-- "GI.Gtk.Declarative.Widget.Conversions", and the shape most markup
-- is written in.
prop_a_box_takes_a_widget_that_is_not_a_box_child = withTests 1 . property $ do
  labels <- evalIO $ renderAll
    [ container
        Gtk.Box
        []
        [ widget Gtk.Label [#label := ("one" :: Text)]
        , widget Gtk.Label [#label := ("two" :: Text)]
        ]
    ]
    childLabels
  labels === ["one", "two"]

tests :: IO Bool
tests = checkParallel $$(discover)
