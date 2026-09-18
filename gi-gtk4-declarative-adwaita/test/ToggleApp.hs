{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A window holding one toggle group, for the input test.
--
-- The reason a toggle group is in this library is a claim about GTK: a
-- click cannot turn the chosen toggle off, the way a click on a
-- 'Gtk.ToggleButton' that is already on turns it off. Nothing can
-- synthesise a click, so this is a real program that
-- @tests\/gui-toggle.sh@ clicks for real.
--
-- It prints a line when somebody chooses a toggle, and it prints what
-- the group says is chosen twice a second, so that the script can read
-- both back.
module ToggleApp where

import           Control.Monad                  ( void )
import           Data.Int                       ( Int32 )
import           Data.IORef
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import qualified GI.Adw                        as Adw
import qualified GI.GLib                       as GLib
import qualified GI.Gtk                        as Gtk
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Adwaita.ToggleGroup
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.State
import           System.IO
import           System.IO.Unsafe               ( unsafePerformIO )

data Event = Chose Text

-- | Where the group puts itself, so that what it says can be read back
-- without asking the markup.
theGroup :: IORef (Maybe Adw.ToggleGroup)
theGroup = unsafePerformIO (newIORef Nothing)
{-# NOINLINE theGroup #-}

markup :: Widget Event
markup = toggleGroup
  [afterCreated (writeIORef theGroup . Just), #hexpand := True]
  defaultToggleGroupParams
    { toggles     = [toggle "9" "9x9", toggle "13" "13x13", toggle "19" "19x19"]
    , active      = Just "9"
    , onActivated = Just Chose
    }

report :: String -> IO ()
report line = do
  hPutStrLn stdout line
  hFlush stdout

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  Adw.init

  state  <- create markup
  widget' <- someStateWidget state
  window <- Gtk.new
    Gtk.Window
    [ #title Gtk.:= ("gi-gtk4-declarative-toggle-test" :: Text)
    , #widthRequest Gtk.:= (300 :: Int32)
    , #heightRequest Gtk.:= (120 :: Int32)
    ]
  Gtk.windowSetChild window (Just widget')
  Gtk.windowPresent window

  _ <- subscribe markup state $ \(Chose name) ->
    report ("CHOSE " <> Text.unpack name)

  -- What the group itself says, twice a second. A toggle group that
  -- let a click turn its chosen toggle off says nothing is chosen.
  _ <- GLib.timeoutAdd 0 500 $ do
    group <- readIORef theGroup
    case group of
      Nothing     -> report "ACTIVE none"
      Just group' -> do
        chosen <- Adw.toggleGroupGetActiveName group'
        report ("ACTIVE " <> maybe "none" Text.unpack chosen)
    pure True

  mainLoop <- GLib.mainLoopNew Nothing False
  void (GLib.mainLoopRun mainLoop)
