{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for the toast overlay.
--
-- A toast is a thing that happens, and markup says what holds, so the
-- whole of this widget is the rule that joins the two: a name that has
-- been shown is not shown again until it goes away.
--
-- An overlay shows one toast at a time and holds the rest in a queue,
-- so what is on the screen after a render does not count them. Each
-- toast here lasts a second and reports as it goes, and the reports in
-- order are what arrived in order.
module GI.Gtk.Declarative.Adwaita.ToastTest where

import           Control.Concurrent.STM
import           Control.Monad                  ( foldM )
import           Data.Text                      ( Text )
import qualified Data.Vector                   as Vector
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Adwaita.TestUtils
import           GI.Gtk.Declarative.Adwaita.ToastOverlay
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.State

data Event
  = Pressed Text
  | Gone Text
  deriving (Eq, Show)

-- | An overlay over a label, showing these toasts.
overlayOf :: [Toast Event] -> Widget Event
overlayOf these = toastOverlay
  []
  (defaultToastOverlayParams (widget Gtk.Label [#label := ("below" :: Text)]))
    { toasts = Vector.fromList these
    }

-- | An overlay saying these names. Each toast says its own name, lasts
-- a second, and reports as it goes.
saying :: [Text] -> Widget Event
saying keys = overlayOf
  [ (toast key key) { toastTimeout = 1, onDismissed = Just (Gone key) }
  | key <- keys
  ]

-- | Render each of these in turn, and say which toasts the overlay
-- showed, in the order it showed them.
collecting :: [[Text]] -> IO [Text]
collecting = collectingEvery 0

-- | The same, with this many milliseconds between one render and the
-- next. A second between two renders is long enough for the toast from
-- the first of them to go.
collectingEvery :: Int -> [[Text]] -> IO [Text]
collectingEvery _    []             = fail "collecting: no markup to render"
collectingEvery gap (first : rest) = do
  received <- newTBQueueIO 20
  let markup = saying first
  state <- runUI (create markup)
  sub   <- runUI (subscribe markup state (atomically . writeTBQueue received))
  _     <- foldM renderNext (state, markup) rest
  gone  <- untilQuiet received
  runUI (cancel sub)
  pure [ key | Gone key <- gone ]
 where
  renderNext (state, old) these = do
    pause gap
    let new = saying these
    state' <- runUI (patch' state old new)
    settle
    pure (state', new)

-- | Take the events the overlay reports, until two seconds go by with
-- none. A toast lasts a second, so a queue that still has something in
-- it reports again well inside that.
untilQuiet :: TBQueue Event -> IO [Event]
untilQuiet received = go [] (0 :: Int)
 where
  go seen quiet = do
    pause 100
    these <- atomically (flushTBQueue received)
    case these of
      [] | quiet >= 20 -> pure (reverse seen)
         | otherwise   -> go seen (quiet + 1)
      _                -> go (reverse these <> seen) 0

-- * The rule

-- | A name that was in the render before is not shown again. A render
-- happens for every event an application takes, so anything else would
-- say the same thing over and over.
prop_a_name_that_was_shown_is_not_shown_again = withTests 1 . property $ do
  said <- evalIO $ collecting [["m1"], ["m1"], ["m1"]]
  said === ["m1"]

-- | Names that are new are shown, however many of them arrive at once.
-- Three messages together are three toasts, which is what a single
-- slot cannot say.
prop_every_new_name_is_shown = withTests 1 . property $ do
  said <- evalIO $ collecting [["m1"], ["m1", "m2", "m3"]]
  said === ["m1", "m2", "m3"]

-- | A name is forgotten when it leaves the markup, so the same name
-- can be used again later.
prop_a_name_that_went_away_can_come_back = withTests 1 . property $ do
  said <- evalIO $ collecting [["m1"], [], ["m1"]]
  said === ["m1", "m1"]

-- | A name that stays in the markup is not shown again, even after its
-- toast has left the screen. To say a thing twice, say it under two
-- names.
prop_a_name_that_stays_is_not_shown_when_its_toast_goes =
  withTests 1 . property $ do
    said <- evalIO $ collectingEvery 2000 [["m1"], ["m1"]]
    said === ["m1"]

-- * What a toast reports

-- | The button is the part of a toast that carries an event.
prop_a_toast_button_reports_what_it_was_given = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let markup = overlayOf
          [ (toast "m1" "take it back")
              { toastButton = Just ("Accept", Pressed "m1")
              , toastTimeout = 0
              }
          ]
    state   <- runUI (create markup)
    overlay <- runUI (someStateWidget state)
    window  <- runUI (presenting overlay)
    sub     <- runUI (subscribe markup state (atomically . writeTBQueue received))
    pause 200
    runUI $ do
      buttons <- toastButtons overlay
      case buttons of
        (button : _) -> () <$ Gtk.widgetActivate button
        []           -> fail "no button on the toast"
    -- A button that is activated rather than pressed reports after a
    -- wait of GTK's own.
    pause 500
    runUI (cancel sub)
    runUI (Gtk.windowDestroy window)
    atomically (flushTBQueue received)
  events === [Pressed "m1"]

-- | A toast reports when it leaves the screen, whoever took it off.
prop_a_dismissed_toast_reports_that_it_is_gone = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let markup = overlayOf
          [(toast "m1" "a message") { toastTimeout = 0
                                    , onDismissed  = Just (Gone "m1")
                                    }
          ]
    state   <- runUI (create markup)
    overlay <- runUI (someStateWidget state)
    window  <- runUI (presenting overlay)
    sub     <- runUI (subscribe markup state (atomically . writeTBQueue received))
    pause 200
    runUI $ do
      buttons <- closeButtons overlay
      case buttons of
        (button : _) -> () <$ Gtk.widgetActivate button
        []           -> fail "no close button on the toast"
    pause 500
    runUI (cancel sub)
    runUI (Gtk.windowDestroy window)
    atomically (flushTBQueue received)
  events === [Gone "m1"]

-- | A toast with no timeout of its own stays up. What the overlay does
-- with it is libadwaita's business, and the test says only that the
-- widget is there to press.
prop_a_toast_is_a_widget_with_a_title_and_a_button =
  withTests 1 . property $ do
    said <- evalIO $ do
      let markup = overlayOf
            [ (toast "m1" "a message") { toastButton  = Just ("Accept", Pressed "m1")
                                       , toastTimeout = 0
                                       }
            ]
      state   <- runUI (create markup)
      overlay <- runUI (someStateWidget state)
      pause 200
      runUI (descendantLabels overlay)
    said === ["below", "a message", "Accept"]

-- * The widget under the toasts

-- | The widget under the toasts is patched like any other child.
prop_the_child_under_the_toasts_is_patched = withTests 1 . property $ do
  labels <- evalIO $ do
    let overlayWith text = toastOverlay
          []
          (defaultToastOverlayParams (widget Gtk.Label [#label := text]))
          :: Widget Event
        first  = overlayWith "before"
        second = overlayWith "after"
    state   <- runUI (create first)
    _       <- runUI (patch' state first second)
    overlay <- runUI (someStateWidget state)
    runUI (descendantLabels overlay)
  labels === ["after"]

-- | A widget under the toasts emits its own events.
prop_the_child_under_the_toasts_emits = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let markup = toastOverlay
          []
          (defaultToastOverlayParams
            (widget Gtk.ToggleButton
                    [#label := ("press" :: Text), on #toggled (Pressed "child")]
            )
          ) :: Widget Event
    state   <- runUI (create markup)
    overlay <- runUI (someStateWidget state)
    sub <- runUI (subscribe markup state (atomically . writeTBQueue received))
    runUI $ do
      widgets <- descendants overlay
      buttons <- traverse (Gtk.castTo Gtk.ToggleButton) widgets
      case foldr (\x xs -> maybe xs (: xs) x) [] buttons of
        (button : _) -> Gtk.toggleButtonSetActive button True
        []           -> fail "no button below the overlay"
    runUI (cancel sub)
    atomically (flushTBQueue received)
  events === [Pressed "child"]

-- * Reading the toasts back

-- | Put a widget on the screen. A button that is activated rather than
-- pressed does nothing until the window it is in is realized.
presenting :: Gtk.Widget -> IO Gtk.Window
presenting content = do
  window <- Gtk.new Gtk.Window []
  Gtk.windowSetChild window (Just content)
  Gtk.windowPresent window
  pure window

-- | The buttons a toast carries, which are the ones with a label.
toastButtons :: Gtk.Widget -> IO [Gtk.Button]
toastButtons overlay = do
  found    <- buttonsBelow overlay
  labelled <- traverse Gtk.buttonGetLabel found
  pure [ button | (button, Just _) <- zip found labelled ]

-- | The close button libadwaita puts on a toast, which is the one with
-- no label.
closeButtons :: Gtk.Widget -> IO [Gtk.Button]
closeButtons overlay = do
  found    <- buttonsBelow overlay
  labelled <- traverse Gtk.buttonGetLabel found
  pure [ button | (button, Nothing) <- zip found labelled ]

buttonsBelow :: Gtk.Widget -> IO [Gtk.Button]
buttonsBelow overlay = do
  widgets <- descendants overlay
  buttons <- traverse (Gtk.castTo Gtk.Button) widgets
  pure (foldr (\x xs -> maybe xs (: xs) x) [] buttons)

tests :: IO Bool
tests = checkParallel $$(discover)
