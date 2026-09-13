{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for the declarative tab view.
--
-- A tab is matched with the tab of the render before by its key, so
-- every test here is about what a key does: keeping a widget, adding a
-- page, taking one away, and the question a close button asks.
module GI.Gtk.Declarative.Adwaita.TabViewTest where

import           Control.Concurrent.STM
import           Control.Monad                  ( foldM )
import           Data.Int                       ( Int32 )
import           Data.Text                      ( Text )
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified GI.Adw                        as Adw
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Adwaita.TabView
import           GI.Gtk.Declarative.Adwaita.TestUtils
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.State

data Event
  = Chose Text
  | Reordered (Vector Text)
  | Closing Text
  | Pressed Text
  deriving (Eq, Show)

-- * Markup

-- | Tabs holding a label each, named by key and title.
labelTabs :: [(Text, Text)] -> TabViewParams Event
labelTabs items =
  defaultTabViewParams { tabs = Vector.fromList (map each items) }
 where
  each (key, title) =
    Tab key title (widget Gtk.Label [#label := ("in " <> title)])

-- | Tabs holding a button each, which is a widget with a state of its
-- own: whether it is pressed.
buttonTabs :: [(Text, Text)] -> TabViewParams Event
buttonTabs items =
  defaultTabViewParams { tabs = Vector.fromList (map each items) }
 where
  each (key, title) = Tab
    key
    title
    (widget Gtk.ToggleButton [#label := title, on #toggled (Pressed key)])

asking :: TabViewParams Event -> TabViewParams Event
asking params = params { onClosePage = Just Closing }

markup :: TabViewParams Event -> Widget Event
markup = tabView []

-- * Rendering and patching

-- | Render markup into a window, and give back the window, the state,
-- and the tab view itself.
--
-- The window is never presented. A tab view holds real widgets rather
-- than rows built for what is on screen, so there is nothing to wait
-- for.
openView :: Widget Event -> IO (Gtk.Window, SomeState, Adw.TabView)
openView first = runUI $ do
  state   <- create first
  widget' <- someStateWidget state
  window  <- Gtk.new Gtk.Window []
  Gtk.windowSetChild window (Just widget')
  view <- Gtk.unsafeCastTo Adw.TabView widget'
  pure (window, state, view)

-- | Render the first markup, patch it with each of the others in turn,
-- and hand the tab view to the action.
renderTabs :: [Widget Event] -> (Adw.TabView -> IO a) -> IO a
renderTabs []             _ = fail "renderTabs: no markup to render"
renderTabs (first : rest) f = do
  (window, state, view) <- openView first
  _                     <- foldM step (state, first) rest
  result                <- runUI (f view)
  runUI (Gtk.windowDestroy window)
  pure result
 where
  step (state, old) new = do
    state' <- runUI (patch' state old new)
    pure (state', new)

-- | The titles of the pages, in the order the view has them.
pageTitles :: Adw.TabView -> IO [Text]
pageTitles view = eachPage view Adw.tabPageGetTitle

-- | The widget in each page, in the order the view has them.
pageChildren :: Adw.TabView -> IO [Gtk.Widget]
pageChildren view = eachPage view Adw.tabPageGetChild

eachPage :: Adw.TabView -> (Adw.TabPage -> IO a) -> IO [a]
eachPage view f = do
  count <- Adw.tabViewGetNPages view
  traverse (\index -> f =<< Adw.tabViewGetNthPage view index)
           [0 .. count - 1 :: Int32]

-- | Close the page at this position, the way the close button on a tab
-- does. Clicking that button cannot be made to happen from code, and
-- this is the signal it sends.
closeFromButton :: Adw.TabView -> Int32 -> IO ()
closeFromButton view position = runUI $ do
  closing <- Adw.tabViewGetNthPage view position
  Adw.tabViewClosePage view closing

-- * The tests

prop_tabs_are_rendered = withTests 1 . property $ do
  (titles, labels) <- evalIO $ renderTabs
    [markup (labelTabs [("a", "First"), ("b", "Second")])]
    (\view -> (,) <$> pageTitles view <*> descendantLabels view)
  titles === ["First", "Second"]
  labels === ["in First", "in Second"]

-- | A tab that keeps its key keeps its page and the widget in it, so a
-- widget with a state of its own keeps that too.
prop_a_tab_that_keeps_its_key_keeps_its_widget = withTests 1 . property $ do
  (same, pressed) <- evalIO $ do
    let first  = markup (buttonTabs [("a", "First"), ("b", "Second")])
        second = markup (buttonTabs [("a", "First"), ("b", "Renamed")])
    (window, state, view) <- openView first
    -- Press the button in the first tab, which is a state GTK holds
    -- and the markup says nothing about.
    before                <- runUI $ do
      children <- pageChildren view
      case children of
        (first' : _) -> do
          button <- Gtk.unsafeCastTo Gtk.ToggleButton first'
          Gtk.toggleButtonSetActive button True
          pure first'
        [] -> fail "no pages"
    _      <- runUI (patch' state first second)
    result <- runUI $ do
      children <- pageChildren view
      case children of
        (first' : _) -> do
          button  <- Gtk.unsafeCastTo Gtk.ToggleButton first'
          active  <- Gtk.toggleButtonGetActive button
          pure (first' == before, active)
        [] -> fail "no pages"
    runUI (Gtk.windowDestroy window)
    pure result
  same === True
  pressed === True

-- | A page holds the widget it was made with, so a tab whose widget
-- has to be replaced is a page that has to be made again. It keeps its
-- key, its title, and its place.
prop_a_tab_whose_widget_is_replaced_keeps_its_place =
  withTests 1 . property $ do
    (titles, kinds) <- evalIO $ do
      let labels = markup (labelTabs [("a", "First"), ("b", "Second")])
          mixed  = markup
            defaultTabViewParams
              { tabs =
                [ Tab "a" "First" (widget Gtk.ToggleButton [#label := ("one" :: Text)])
                , Tab "b" "Second" (widget Gtk.Label [#label := ("two" :: Text)])
                ]
              }
      (window, state, view) <- openView labels
      _                     <- runUI (patch' state labels mixed)
      result                <- runUI $ do
        titles'   <- pageTitles view
        children  <- pageChildren view
        buttons   <- traverse (Gtk.castTo Gtk.ToggleButton) children
        pure (titles', map (maybe "other" (const "button")) buttons)
      runUI (Gtk.windowDestroy window)
      pure result
    titles === ["First", "Second"]
    kinds === ["button", "other"]

-- | A key that was not there before is a page that was not there
-- before, and the pages end up in the order the vector is in.
prop_a_new_key_is_appended_in_the_right_place = withTests 1 . property $ do
  titles <- evalIO $ renderTabs
    [ markup (labelTabs [("a", "First"), ("b", "Second")])
    , markup (labelTabs [("a", "First"), ("c", "Middle"), ("b", "Second")])
    ]
    pageTitles
  titles === ["First", "Middle", "Second"]

-- | A tab the markup no longer names closes, and nobody is asked about
-- it, even though somebody is there to ask.
prop_a_dropped_key_closes_without_asking = withTests 1 . property $ do
  (titles, events) <- evalIO $ do
    received <- newTBQueueIO 10
    let first  = markup (asking (labelTabs [("a", "First"), ("b", "Second")]))
        second = markup (asking (labelTabs [("a", "First")]))
    (window, state, view) <- openView first
    sub    <- runUI (subscribe first state (atomically . writeTBQueue received))
    _      <- runUI (patch' state first second)
    titles <- runUI (pageTitles view)
    runUI $ do
      cancel sub
      Gtk.windowDestroy window
    events <- atomically (flushTBQueue received)
    pure (titles, events)
  titles === ["First"]
  events === []

-- | A close from the tab's own button asks, and the page stays until
-- the answer comes back in a later render.
prop_a_close_from_the_button_waits_for_the_answer = withTests 1 . property $ do
  (asked, afterAsking, afterNo, askedAgain, afterYes) <- evalIO $ do
    received <- newTBQueueIO 10
    let both  = markup (asking (labelTabs [("a", "First"), ("b", "Second")]))
        no    = markup (asking (labelTabs [("a", "First"), ("b", "Second")]))
          { closeAnswer = Just ("b", False)
          }
        yes = markup
          (asking (labelTabs [("a", "First")])) { closeAnswer = Just ("b", True)
                                                }
    (window, state, view) <- openView both
    sub <- runUI (subscribe both state (atomically . writeTBQueue received))

    -- Somebody clicks the close button on the second tab.
    closeFromButton view 1
    asked       <- atomically (flushTBQueue received)
    afterAsking <- runUI (pageTitles view)

    -- The program says no, and the tab stays.
    _           <- runUI (patch' state both no)
    afterNo     <- runUI (pageTitles view)

    -- The button still works, which says that refusing left the page
    -- as it was.
    closeFromButton view 1
    askedAgain <- atomically (flushTBQueue received)

    -- The program says yes, and takes the tab out of the markup, which
    -- is what a program does once it knows the answer.
    _          <- runUI (patch' state no yes)
    afterYes   <- runUI (pageTitles view)
    runUI $ do
      cancel sub
      Gtk.windowDestroy window
    pure (asked, afterAsking, afterNo, askedAgain, afterYes)
  asked === [Closing "b"]
  afterAsking === ["First", "Second"]
  afterNo === ["First", "Second"]
  askedAgain === [Closing "b"]
  afterYes === ["First"]

-- | Nothing stops a person clicking the close button on a second tab
-- while the first is still being asked about, so a close waits for its
-- own answer rather than for the next one.
prop_two_closes_can_wait_at_once = withTests 1 . property $ do
  (asked, waiting, afterYes, afterNo) <- evalIO $ do
    received <- newTBQueueIO 10
    let both = markup (asking (labelTabs [("a", "First"), ("b", "Second")]))
        yes  = markup
          (asking (labelTabs [("b", "Second")])) { closeAnswer = Just ("a", True)
                                                 }
        no = markup (asking (labelTabs [("b", "Second")]))
          { closeAnswer = Just ("b", False)
          }
    (window, state, view) <- openView both
    sub      <- runUI (subscribe both state (atomically . writeTBQueue received))
    closeFromButton view 0
    closeFromButton view 1
    asked    <- atomically (flushTBQueue received)
    waiting  <- runUI (pageTitles view)
    _        <- runUI (patch' state both yes)
    afterYes <- runUI (pageTitles view)
    _        <- runUI (patch' state yes no)
    afterNo  <- runUI (pageTitles view)
    runUI $ do
      cancel sub
      Gtk.windowDestroy window
    pure (asked, waiting, afterYes, afterNo)
  asked === [Closing "a", Closing "b"]
  waiting === ["First", "Second"]
  afterYes === ["Second"]
  afterNo === ["Second"]

-- | A view with nobody to ask holds nothing open: the close button
-- does nothing at all, and taking the tab out of the markup is what
-- closes it.
prop_a_close_with_nobody_to_ask_does_nothing = withTests 1 . property $ do
  titles <- evalIO $ do
    let only = markup (labelTabs [("a", "First"), ("b", "Second")])
    (window, _state, view) <- openView only
    closeFromButton view 1
    titles <- runUI (pageTitles view)
    runUI (Gtk.windowDestroy window)
    pure titles
  titles === ["First", "Second"]

-- | Somebody else selecting a tab emits. A selection this markup asked
-- for does not, because a program does not need telling what it just
-- said.
prop_selecting_a_tab_emits = withTests 1 . property $ do
  (fromMarkup, fromElsewhere) <- evalIO $ do
    received <- newTBQueueIO 10
    let chosen = (labelTabs [("a", "First"), ("b", "Second")])
          { onSelected = Just Chose
          }
        first  = markup chosen
        second = markup chosen { selected = Just "b" }
    (window, state, view) <- openView first
    sub <- runUI (subscribe first state (atomically . writeTBQueue received))
    _          <- runUI (patch' state first second)
    fromMarkup <- atomically (flushTBQueue received)
    runUI $ do
      chosen' <- Adw.tabViewGetNthPage view 0
      Adw.tabViewSetSelectedPage view chosen'
    fromElsewhere <- atomically (flushTBQueue received)
    runUI $ do
      cancel sub
      Gtk.windowDestroy window
    pure (fromMarkup, fromElsewhere)
  fromMarkup === []
  fromElsewhere === [Chose "a"]

-- | Dragging a tab somewhere else reports every key, in the order they
-- are in now.
prop_reordering_a_tab_emits_the_new_order = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let dragged = markup
          (labelTabs [("a", "First"), ("b", "Second"), ("c", "Third")])
            { onReordered = Just Reordered
            }
    (window, state, view) <- openView dragged
    sub <- runUI (subscribe dragged state (atomically . writeTBQueue received))
    runUI $ do
      moved <- Adw.tabViewGetNthPage view 2
      _     <- Adw.tabViewReorderPage view moved 0
      pure ()
    events <- atomically (flushTBQueue received)
    runUI $ do
      cancel sub
      Gtk.windowDestroy window
    pure events
  events === [Reordered ["c", "a", "b"]]

-- | A widget in a tab emits through the view, which is what says the
-- tabs are subscribed to.
prop_a_widget_in_a_tab_emits_its_events = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let buttons = markup (buttonTabs [("a", "First"), ("b", "Second")])
    (window, state, view) <- openView buttons
    sub <- runUI (subscribe buttons state (atomically . writeTBQueue received))
    runUI $ do
      children <- pageChildren view
      case children of
        (_ : second : _) -> do
          button <- Gtk.unsafeCastTo Gtk.ToggleButton second
          Gtk.toggleButtonSetActive button True
        _ -> fail "no pages"
    events <- atomically (flushTBQueue received)
    runUI $ do
      cancel sub
      Gtk.windowDestroy window
    pure events
  events === [Pressed "b"]

tests :: IO Bool
tests = checkParallel $$(discover)
