{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Example of the 'Gtk.Stack' and 'Gtk.HeaderBar' containers.
module Stack where

import           Control.Monad                  ( void )
import           Data.Text                      ( Text )
import qualified GI.Gtk                        as Gtk
import           GI.Gtk                         ( Box(..)
                                                , Button(..)
                                                , HeaderBar(..)
                                                , Label(..)
                                                , Orientation(..)
                                                , Stack(..)
                                                , Window(..)
                                                )
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.App.Simple
import           GI.Gtk.Declarative.Container.HeaderBar
import           GI.Gtk.Declarative.Container.Stack

newtype State = State { visible :: Text }

data Event = Show' Text | Closed

view' :: State -> AppView Window Event
view' State { visible } =
  bin
      Window
      [ #title := "Stack"
      , on #closeRequest (True, Closed)
      , #widthRequest := 400
      , #heightRequest := 300
      ]
    $ container
        Box
        [#orientation := OrientationVertical]
        [ BoxChild defaultBoxChildProperties { fill = True } $ container
          HeaderBar
          [#showTitleButtons := False]
          [ headerBarStart
            (widget Button [#label := "First", on #clicked (Show' "first")])
          , headerBarEnd
            (widget Button [#label := "Second", on #clicked (Show' "second")])
          , headerBarTitle (widget Label [#label := visible])
          ]
        , BoxChild defaultBoxChildProperties { expand = True, fill = True }
          $ container
              Stack
              [#visibleChildName := visible, #transitionType := transition]
              [ StackChild
                defaultStackChildProperties { name  = "first"
                                            , title = Just "First"
                                            }
                (widget Label [#label := "The first page."])
              , StackChild
                defaultStackChildProperties { name  = "second"
                                            , title = Just "Second"
                                            }
                (widget Label [#label := "The second page."])
              ]
        ]
  where transition = Gtk.StackTransitionTypeSlideLeftRight

update' :: State -> Event -> Transition State Event
update' _ = \case
  Show' name -> Transition (State name) (return Nothing)
  Closed     -> Exit

main :: IO ()
main = void $ run App { view         = view'
                      , update       = update'
                      , inputs       = []
                      , initialState = State "first"
                      }
