{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}

module MenuBar where

import           Control.Monad                  ( void )
import           Data.Text                      ( Text )
import           GI.Gtk                         ( Box(..)
                                                , Label(..)
                                                , Orientation(..)
                                                , Window(..)
                                                )
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.App.Simple

newtype State = Message Text

data Event = Open | Save | Help | Closed

view' :: State -> AppView Window Event
view' (Message msg) =
  bin
      Window
      [ #title := "MenuBar"
      , on #closeRequest (True, Closed)
      , #widthRequest := 400
      , #heightRequest := 300
      ]
    $ container
        Box
        [#orientation := OrientationVertical]
        [ BoxChild defaultBoxChildProperties { fill = True } $ menuBar
          []
          [ subMenu
            "File"
            [ menuSection Nothing [menuItem "Open" Open, menuItem "Save" Save]
            ]
          , subMenu "Help" [menuItem "Help" Help]
          ]
        , BoxChild defaultBoxChildProperties { expand = True, fill = True }
          $ widget Label [#label := msg]
        ]

update' :: State -> Event -> Transition State Event
update' _ = \case
  Open   -> Transition (Message "Opening file...") none
  Save   -> Transition (Message "Saving file...") none
  Help   -> Transition (Message "There is no help.") none
  Closed -> Exit

main :: IO ()
main = void $ run defaultApp { view         = view'
                      , update       = update'
                      , inputs       = []
                      , initialState = Message "Click a button in the menu."
                      }
