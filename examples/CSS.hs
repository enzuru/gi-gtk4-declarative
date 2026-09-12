{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}

module CSS where

import           Control.Concurrent.Async       ( async )
import           Control.Monad                  ( void )
import           Data.Functor                   ( (<&>) )
import           Data.Text                      ( Text )
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified GI.Gdk                        as Gdk
import qualified GI.GLib                       as GLib
import           GI.Gtk                         ( Box(..)
                                                , Button(..)
                                                , Orientation(..)
                                                , Window(..)
                                                )
import qualified GI.Gtk                        as Gtk
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.App.Simple

type State = Int

data Event
  = MoveTo Int
  | Closed

colors :: Vector Text
colors = ["red", "green", "blue", "yellow"]

view' :: State -> AppView Window Event
view' si =
  bin Window [#title := "CSS Example", on #closeRequest (True, Closed)]
    $ container
        Box
        [#orientation := OrientationVertical]
        [ BoxChild defaultBoxChildProperties { expand = True, padding = 10 }
            $ container Box [#orientation := OrientationHorizontal] colorButtons
        ]
 where
  colorButtons = Vector.indexed colors <&> \(i, color) ->
    BoxChild defaultBoxChildProperties { expand = True, padding = 10 }
      $ let cs = if i == si then ["selected", color] else [color]
        in  widget Button [#label := color, on #clicked (MoveTo i), classes cs]

update' :: State -> Event -> Transition State Event
update' s (MoveTo i)
  | i >= 0 && i < length colors = Transition i (return Nothing)
  | otherwise                   = Transition s (return Nothing)
update' _ Closed = Exit

styles :: Text
styles = mconcat
  [ "button { border: 2px solid gray; font-weight: 800; }"
  , ".selected { background: white; border: 2px solid black; }"
  -- Specific color classes:
  , ".red { color: red; }"
  , ".green { color: green; }"
  , ".blue { color: blue; }"
  , ".yellow { color: goldenrod; }"
  ]

main :: IO ()
main = do
  Gtk.init

  -- Set up the display and the CSS provider. In GTK 4 a provider is
  -- added for a display, not for a screen.
  display <- maybe (fail "No display?!") return =<< Gdk.displayGetDefault
  p       <- Gtk.cssProviderNew
  Gtk.cssProviderLoadFromString p styles
  Gtk.styleContextAddProviderForDisplay
    display
    p
    (fromIntegral Gtk.STYLE_PROVIDER_PRIORITY_USER)

  -- Start main loop
  mainLoop <- GLib.mainLoopNew Nothing False
  void . async $ do
    void $ runLoop app
    GLib.mainLoopQuit mainLoop
  GLib.mainLoopRun mainLoop
 where
  app = App { view = view', update = update', inputs = [], initialState = 0 }
