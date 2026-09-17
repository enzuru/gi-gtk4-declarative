{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

-- | Example of a column view.
--
-- A column view takes its rows as data and a way to render one cell of
-- a row, rather than a tree of widgets, because it builds a widget only
-- for what is on screen. The rows here are people, and the columns are
-- what to say about one.
module Columns where

import           Control.Monad                  ( void )
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import           GI.Gtk                         ( Box(..)
                                                , Label(..)
                                                , Orientation(..)
                                                , ScrolledWindow(..)
                                                , Window(..)
                                                )
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.App.Simple
import           GI.Gtk.Declarative.ModelView.ColumnView

data Person = Person
  { personName :: Text
  , personRole :: Text
  }

data State = State
  { people :: Vector Person
  , chosen :: Maybe Word
  }

data Event = Chose Word | Opened Word | Closed

-- | One cell: a label, left aligned.
cell :: Text -> Widget Event
cell text = widget Label [#label := text, #xalign := 0]

view' :: State -> AppView Window Event
view' State {..} =
  bin
      Window
      [ #title := "Columns"
      , on #closeRequest (True, Closed)
      , #defaultWidth := 500
      , #defaultHeight := 400
      ]
    $ container
        Box
        [#orientation := OrientationVertical, #spacing := 6]
        [ BoxChild defaultBoxChildProperties { expand = True, fill = True }
          $ bin ScrolledWindow []
          $ columnView
              []
              (defaultColumnViewParams
                  [ column "name" "Name" (cell . personName)
                  , (column "role" "Role" (cell . personRole))
                    { columnExpand = True
                    }
                  ]
                )
                { rows        = people
                , selected    = chosen
                , onSelected  = Just Chose
                , onActivated = Just Opened
                }
        , BoxChild defaultBoxChildProperties { fill = True }
          $ widget Label [#label := status, #xalign := 0]
        ]
 where
  status = case chosen >>= (people Vector.!?) . fromIntegral of
    Nothing     -> "Nobody is selected."
    Just person -> personName person <> " is selected."

update' :: State -> Event -> Transition State Event
update' state = \case
  Chose row  -> Transition state { chosen = Just row } none
  Opened row -> Transition state (perform (report row))
  Closed     -> Exit
 where
  report row = do
    putStrLn ("Row " <> show row <> " was opened.")
    pure Nothing

main :: IO ()
main = void $ run defaultApp { view         = view'
                      , update       = update'
                      , inputs       = []
                      , initialState = State { people = staff, chosen = Nothing }
                      }

staff :: Vector Person
staff =
  [ Person "Ada Lovelace"      "Analyst"
  , Person "Grace Hopper"      "Rear Admiral"
  , Person "Alan Turing"       "Cryptanalyst"
  , Person "Katherine Johnson" "Mathematician"
  , Person "Edsger Dijkstra"   "Professor"
  ]
