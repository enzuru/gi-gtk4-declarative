{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Example of a stack, a header bar, and a switcher that points at the
-- stack.
--
-- This is the arrangement GNOME applications use: the switcher sits in
-- the window's title bar and the stack fills the body, so the two are
-- in different parts of the tree. They are joined by name, with
-- `#name` on the stack and `switcherStack` on the switcher.
module Stack where

import           Control.Monad                  ( void )
import qualified GI.Gtk                        as Gtk
import           GI.Gtk                         ( HeaderBar(..)
                                                , Label(..)
                                                , Stack(..)
                                                , StackSwitcher(..)
                                                , Window(..)
                                                )
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.App.Simple
import           GI.Gtk.Declarative.Container.HeaderBar
import           GI.Gtk.Declarative.Container.Stack

data State = State

data Event = Closed

view' :: State -> AppView Window Event
view' State =
  bin
      Window
      [ #title := "Stack"
      , on #closeRequest (True, Closed)
      , #widthRequest := 400
      , #heightRequest := 300
      -- The header bar goes where the window manager would otherwise
      -- put a title bar, and the switcher in it points at the stack
      -- below by name.
      , titlebar $ container
        HeaderBar
        []
        [headerBarTitle (widget StackSwitcher [switcherStack "pages"])]
      ]
    $ container
        Stack
        [#name := "pages", #transitionType := transition]
        [ StackChild
          defaultStackChildProperties { name = "first", title = Just "First" }
          (widget Label [#label := "The first page."])
        , StackChild
          defaultStackChildProperties { name  = "second"
                                      , title = Just "Second"
                                      }
          (widget Label [#label := "The second page."])
        ]
  where transition = Gtk.StackTransitionTypeSlideLeftRight

update' :: State -> Event -> Transition State Event
update' State = \case
  Closed -> Exit

main :: IO ()
main = void $ run defaultApp { view         = view'
                      , update       = update'
                      , inputs       = []
                      , initialState = State
                      }
