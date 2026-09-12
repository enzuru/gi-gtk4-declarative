{-# LANGUAGE LambdaCase #-}
module Main where

import           System.Environment
import           System.IO

import qualified AddBoxes
import qualified CSS
import qualified Controllers
import qualified CustomWidget
import qualified Dialog
import qualified Exit
import qualified FileChooser
import qualified Functor
import qualified Grid
import qualified Hello
import qualified ListBox
import qualified ManyBoxes
import qualified MenuBar
import qualified Notebook
import qualified Paned
import qualified Stack

main :: IO ()
main =
  let examples =
          [ ("AddBoxes"         , AddBoxes.main)
          , ("CustomWidget"     , CustomWidget.main)
          , ("Controllers"      , Controllers.main)
          , ("FileChooser"      , FileChooser.main)
          , ("Hello"            , Hello.main)
          , ("ListBox"          , ListBox.main)
          , ("Functor"          , Functor.main)
          , ("Grid"             , Grid.main)
          , ("Exit"             , Exit.main)
          , ("ManyBoxes"        , ManyBoxes.main)
          , ("MenuBar"          , MenuBar.main)
          , ("Notebook"         , Notebook.main)
          , ("CSS"              , CSS.main)
          , ("Paned"            , Paned.main)
          , ("Stack"            , Stack.main)
          , ("Dialog"           , Dialog.main)
          ]
  in  getArgs >>= \case
        [example] -> case lookup example examples of
          Just main' -> main'
          Nothing ->
            hPutStrLn stderr ("No example available with name: " <> example)
        _ -> hPutStrLn
          stderr
          (  "Usage: gi-gtk4-declarative-example NAME\n\nWhere NAME is any of:\n"
          <> unlines (map (("  " <>) . fst) examples)
          )
