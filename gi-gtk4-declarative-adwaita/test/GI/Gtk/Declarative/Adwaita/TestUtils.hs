{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedStrings #-}

-- | What the libadwaita tests need to talk to GTK. The core package's
-- suite has a module of the same shape, which this one cannot import:
-- the two are test directories rather than libraries.
module GI.Gtk.Declarative.Adwaita.TestUtils where

import           Control.Concurrent
import           Control.Monad.IO.Class
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import qualified GI.GLib                       as GLib
import qualified GI.Gtk                        as Gtk
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.State

-- | Run an action on the GTK main loop's thread, and wait for it.
runUI :: MonadIO m => IO b -> m b
runUI ma = do
  ret <- liftIO newEmptyMVar
  _   <- GLib.idleAdd GLib.PRIORITY_DEFAULT $ do
    ma >>= putMVar ret
    return False
  liftIO (takeMVar ret)

-- | Let the main loop run whatever is waiting on it, and come back
-- when it has.
settle :: MonadIO m => m ()
settle = runUI (pure ())

patch'
  :: Patchable widget => SomeState -> widget e1 -> widget e2 -> IO SomeState
patch' state markup1 markup2 = case patch state markup1 markup2 of
  Keep      -> pure state
  Modify  f -> f
  Replace f -> f

-- | The label of a widget, or the empty text if it has none.
labelOf :: Gtk.Widget -> IO Text
labelOf w = do
  asLabel <- Gtk.castTo Gtk.Label w
  case asLabel of
    Just l  -> Gtk.get l #label
    Nothing -> pure ""

-- | Every widget below this one, in tree order, this one included.
descendants :: Gtk.IsWidget parent => parent -> IO [Gtk.Widget]
descendants root = Gtk.toWidget root >>= go
 where
  go w = do
    children <- childrenOf w
    below    <- concat <$> traverse go children
    pure (w : below)

-- | The labels below a widget, in tree order.
descendantLabels :: Gtk.IsWidget parent => parent -> IO [Text]
descendantLabels root = Gtk.toWidget root >>= go
 where
  go w = do
    label    <- labelOf w
    children <- childrenOf w
    below    <- concat <$> traverse go children
    pure (if Text.null label then below else label : below)

childrenOf :: Gtk.Widget -> IO [Gtk.Widget]
childrenOf w = go =<< Gtk.widgetGetFirstChild w
 where
  go Nothing     = pure []
  go (Just next) = (next :) <$> (go =<< Gtk.widgetGetNextSibling next)
