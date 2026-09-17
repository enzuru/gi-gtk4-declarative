{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Example of choosing a file.
--
-- GTK 4 removed @GtkFileChooserButton@, and a file is now chosen with a
-- 'Gtk.FileDialog', which answers in a callback rather than by
-- returning. The answer is fed back into the application through one of
-- its 'inputs', which is the way to get an event out of any callback
-- that cannot answer on the spot.
module FileChooser where

import           Control.Exception              ( SomeException
                                                , try
                                                )
import           Control.Monad                  ( void )
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import qualified GI.Gio                        as Gio
import           GI.Gtk                         ( Box(..)
                                                , Button(..)
                                                , Label(..)
                                                , Orientation(..)
                                                , Window(..)
                                                )
import qualified GI.Gtk                        as Gtk
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.App.Simple
import           Pipes.Concurrent

data State = Started (Maybe Text) | Done Text

data Event
  = FileSelectionChanged (Maybe Text)
  | DialogOpened
  | ButtonClicked
  | Closed

view' :: Output Event -> State -> AppView Window Event
view' output s =
  bin
      Window
      [ #title := "File Chooser"
      , on #closeRequest (True, Closed)
      , #widthRequest := 400
      , #heightRequest := 300
      ]
    $ case s of
        Done path -> widget Label [#label := (path <> " was selected.")]
        Started currentFile -> container
          Box
          [#orientation := OrientationVertical]
          [ BoxChild defaultBoxChildProperties { expand = True, fill = True }
            $ widget Label
                     [#label := maybe "No file yet." id currentFile]
          , BoxChild defaultBoxChildProperties { padding = 10 } $ widget
            Button
            [ #label := "Select file..."
            , onM #clicked (\_button -> DialogOpened <$ chooseFile output)
            ]
          , BoxChild defaultBoxChildProperties { padding = 10 } $ widget
            Button
            [ #label := "Confirm"
            , #tooltipText := "Confirm the chosen file"
            , on #clicked ButtonClicked
            ]
          ]

-- | Put up a file dialog, and send the answer back to the application
-- when it comes.
chooseFile :: Output Event -> IO ()
chooseFile output = do
  dialog <- Gtk.fileDialogNew
  Gtk.fileDialogOpen dialog
                     (Nothing :: Maybe Gtk.Window)
                     (Nothing :: Maybe Gio.Cancellable)
    $ Just
    $ \_source result -> do
        chosen <- try (Gtk.fileDialogOpenFinish dialog result)
        path   <- case chosen of
          -- The dialog raises when it is dismissed, which is not an
          -- error worth reporting.
          Left  (_ :: SomeException) -> pure Nothing
          Right file                 -> fmap Text.pack <$> Gio.fileGetPath file
        void (atomically (send output (FileSelectionChanged path)))

update' :: State -> Event -> Transition State Event
update' (Started _) (FileSelectionChanged p) =
  Transition (Started p) none
update' (Started (Just path)) ButtonClicked =
  Transition (Done path) none
update' _ Closed = Exit
update' s _      = Transition s none

main :: IO ()
main = do
  (output, input) <- spawn unbounded
  void $ run defaultApp { view         = view' output
                 , update       = update'
                 , inputs       = [fromInput input]
                 , initialState = Started Nothing
                 }
