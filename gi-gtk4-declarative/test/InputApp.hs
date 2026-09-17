{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}

-- | An application for the input test.
--
-- Keys, clicks, and pointer motion arrive through event controllers,
-- and nothing in GTK 4 can make one happen from code: there is no way
-- to synthesise the events. So this is a real application, which
-- @tests\/gui-input.sh@ drives with real X11 input and reads the
-- answers from its output.
module InputApp where

import           Control.Monad                  ( void )
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           GI.Gtk                         ( Label(..)
                                                , Window(..)
                                                )
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.App.Simple
import           System.IO

data Event
  = KeyPressed Word
  | Clicked Int Int Int
  | Closed

view' :: Text -> AppView Window Event
view' shown =
  bin
      Window
      [ #title := "gi-gtk4-declarative-input-test"
      , on #closeRequest (True, Closed)
      , #widthRequest := 300
      , #heightRequest := 200
      , onKeyPressed
        (\keyval _keycode _modifiers -> (True, KeyPressed (fromIntegral keyval)))
      ]
    $ widget
        Label
        [ #label := shown
        , onClickPressed
          (\nPress x y -> Clicked (fromIntegral nPress) (round x) (round y))
        ]

update' :: Text -> Event -> Transition Text Event
update' _ = \case
  KeyPressed keyval -> report ("KEY " <> Text.pack (show keyval))
  -- The number of presses is what says a double click arrived as one:
  -- the state changes on every click, so the gesture has to live
  -- through the patch that follows the first one to count the second.
  Clicked nPress x y ->
    report
      (  "CLICK "
      <> Text.pack (show nPress)
      <> " "
      <> Text.pack (show x)
      <> " "
      <> Text.pack (show y)
      )
  Closed -> Exit
 where
  report line = Transition line . perform $ do
    hPutStrLn stdout (Text.unpack line)
    hFlush stdout
    pure Nothing

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  void $ run App { view         = view'
                 , update       = update'
                 , inputs       = []
                 , initialState = "nothing yet"
                 }
