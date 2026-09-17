{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

-- | Example of event controllers.
--
-- GTK 4 reports keys, clicks, and pointer motion through controllers
-- added to a widget, rather than through signals on the widget itself.
-- Each of the three below is an attribute in an attribute list, so
-- they read like any other event handler.
module Controllers where

import           Control.Monad                  ( void )
import           Data.Maybe                     ( fromMaybe )
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import qualified GI.Gdk                        as Gdk
import           GI.Gtk                         ( Box(..)
                                                , Label(..)
                                                , Orientation(..)
                                                , Window(..)
                                                )
import qualified GI.Gtk                        as Gtk
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.App.Simple

data State = State
  { lastKey   :: Text
  , lastClick :: Text
  , pointerAt :: Text
  }

data Event
  = KeyPressed Text
  | Clicked Double Double
  | Moved Double Double
  | Closed

view' :: State -> AppView Window Event
view' State {..} =
  bin
      Window
      [ #title := "Event Controllers"
      , on #closeRequest (True, Closed)
      , #widthRequest := 400
      , #heightRequest := 300
      -- A key goes to the window when nothing inside it has taken the
      -- focus. This handler is the impure kind, so that it can ask GDK
      -- what the key is called.
      , onControllerM
        Gtk.eventControllerKeyNew
        #keyPressed
        (\keyval _keycode _modifiers _window -> do
          name <- Gdk.keyvalName keyval
          pure (True, KeyPressed (fromMaybe "?" name))
        )
      ]
    $ container
        Box
        [ #orientation := OrientationVertical
        , #spacing := 10
        , onClickPressed (\_nPress x y -> Clicked x y)
        , onMotion Moved
        ]
        [ line ("Last key: " <> lastKey)
        , line ("Last click: " <> lastClick)
        , line ("Pointer: " <> pointerAt)
        ]
 where
  line text = BoxChild defaultBoxChildProperties { expand = True, fill = True }
    $ widget Label [#label := text]

update' :: State -> Event -> Transition State Event
update' state = \case
  KeyPressed key -> Transition state { lastKey = key } none
  Clicked x y    -> Transition state { lastClick = at x y } none
  Moved   x y    -> Transition state { pointerAt = at x y } none
  Closed         -> Exit

at :: Double -> Double -> Text
at x y = Text.pack (show (round x :: Int) <> ", " <> show (round y :: Int))

main :: IO ()
main = void $ run App
  { view         = view'
  , update       = update'
  , inputs       = []
  , initialState = State { lastKey   = "press a key"
                         , lastClick = "click somewhere"
                         , pointerAt = "move the pointer"
                         }
  }
