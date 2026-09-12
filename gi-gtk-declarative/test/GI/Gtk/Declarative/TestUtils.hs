{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module GI.Gtk.Declarative.TestUtils where

import           Control.Concurrent
import           Control.Exception.Safe         ( bracket )
import           Control.Monad                  ( foldM )
import           Control.Monad.IO.Class
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified GI.GLib                       as GLib
import qualified GI.Gtk                        as Gtk
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Container.Class
                                                ( childWidgets )
import           GI.Gtk.Declarative.State

-- | Run an action on the GTK main loop's thread, and wait for it.
runUI :: MonadIO m => IO b -> m b
runUI ma = do
  ret <- liftIO newEmptyMVar
  _   <- GLib.idleAdd GLib.PRIORITY_DEFAULT $ do
    ma >>= putMVar ret
    return False
  liftIO (takeMVar ret)

-- | Let the main loop run whatever is waiting on it, such as the
-- references a render left to resolve, and come back when it has.
settle :: MonadIO m => m ()
settle = runUI (pure ())

patch'
  :: Patchable widget => SomeState -> widget e1 -> widget e2 -> IO SomeState
patch' state markup1 markup2 = case patch state markup1 markup2 of
  Keep      -> pure state
  Modify  f -> f
  Replace f -> f

-- | Render the first markup in a window, patch it with each of the
-- others in turn, and hand the resulting GTK widget to the given
-- action. The window is taken down afterwards.
renderAll :: [Widget event] -> (Gtk.Widget -> IO a) -> IO a
renderAll []             _ = fail "renderAll: no markup to render"
renderAll (first : rest) f = runUI
  $ bracket (Gtk.new Gtk.Window []) Gtk.windowDestroy
  $ \window -> do
      firstState <- create first
      setWindowChild window firstState
      (lastState, _) <- foldM (step window) (firstState, first) rest
      f =<< someStateWidget lastState
 where
  step window (state, old) new = do
    state' <- patch' state old new
    setWindowChild window state'
    pure (state', new)

-- | Put a rendered widget in a window, unless it is already there.
setWindowChild :: Gtk.Window -> SomeState -> IO ()
setWindowChild window state = do
  widget' <- someStateWidget state
  current <- Gtk.windowGetChild window
  if current == Just widget'
    then pure ()
    else Gtk.windowSetChild window (Just widget')

-- | The labels of a widget's own children, in order. Anything that is
-- not a label or a button reads as the empty text.
childLabels :: Gtk.IsWidget parent => parent -> IO (Vector Text)
childLabels parent = childWidgets parent >>= traverse labelOf

-- | The labels of every widget below this one, in tree order. A widget
-- that has a label of its own is not descended into, so a button reads
-- as one label rather than two.
descendantLabels :: Gtk.IsWidget parent => parent -> IO [Text]
descendantLabels root = Gtk.toWidget root >>= go
 where
  go w = do
    label <- labelOf w
    if Text.null label
      then do
        children <- childWidgets w
        concat <$> traverse go (Vector.toList children)
      else pure [label]

-- | The labels of the children of a widget's children, which is where
-- they are for a list box or a flow box.
nestedChildLabels :: Gtk.IsWidget parent => parent -> IO (Vector Text)
nestedChildLabels parent = do
  children <- childWidgets parent
  traverse (fmap (maybe "" id) . firstChildLabel) children
 where
  firstChildLabel w = do
    child <- Gtk.widgetGetFirstChild w
    traverse labelOf child

-- | The label of a widget, if it is one of the widgets that has one.
labelOf :: Gtk.Widget -> IO Text
labelOf w = do
  asLabel <- Gtk.castTo Gtk.Label w
  case asLabel of
    Just l  -> Gtk.get l #label
    Nothing -> do
      asButton <- Gtk.castTo Gtk.Button w
      case asButton of
        Just b  -> maybe "" id <$> Gtk.get b #label
        Nothing -> pure ""
