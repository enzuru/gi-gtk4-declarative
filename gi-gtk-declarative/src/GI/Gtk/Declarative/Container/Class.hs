{-# LANGUAGE DefaultSignatures      #-}
{-# LANGUAGE DeriveFunctor          #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE TypeOperators          #-}

-- | Shared interfaces for containers.
module GI.Gtk.Declarative.Container.Class
  ( IsContainer(..)
  , Children(..)
  , ToChildren(..)
  , childAtIndex
  , childIndex
  , childWidgets
  )
where

import           Control.Monad.IO.Class         ( MonadIO )
import           Data.Int                       ( Int32 )
import           Data.Proxy                     ( Proxy )
import           Data.Text                      ( Text )
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified GI.Gtk                        as Gtk

-- | Describes supported GTK containers and their specialized APIs for
-- appending, replacing, and removing child widgets. GTK 4 removed
-- @GtkContainer@, so every container has its own way of managing
-- children, and an instance of this class is what makes a widget
-- usable with 'GI.Gtk.Declarative.Container.container'.
class IsContainer container child | container -> child where
  -- | Append a child widget to the container.
  appendChild
    :: container    -- ^ Container widget
    -> child event  -- ^ Declarative child widget
    -> Gtk.Widget   -- ^ GTK child widget to append
    -> IO ()
  -- | Replace the child widget at the given index in the container.
  replaceChild
    :: container    -- ^ Container widget
    -> child event  -- ^ Declarative child widget
    -> Int32        -- ^ Index to replace at
    -> Gtk.Widget   -- ^ Old GTK widget to replace
    -> Gtk.Widget   -- ^ New GTK widget to replace with
    -> IO ()
  -- | Remove a child widget from the container. In GTK 4 a widget is
  -- not destroyed on its own; it is removed from its parent, and the
  -- last reference going away is what destroys it.
  removeChild
    :: container    -- ^ Container widget
    -> Gtk.Widget   -- ^ GTK child widget to remove
    -> IO ()
  -- | The names of the properties that only take once the container
  -- has its children, such as a stack's @visibleChildName@. These are
  -- set after the children are added, rather than when the widget is
  -- constructed, where GTK would warn and ignore them.
  deferredProperties :: Proxy container -> [Text]
  deferredProperties _ = []

-- | Common collection type for child widgets, used when patching containers.
newtype Children child event = Children { unChildren :: Vector (child event) }
  deriving (Functor)

-- | Converts a specific collection type to 'Children'.
class ToChildren widget parent child | widget -> parent, widget -> child where
  toChildren :: (Gtk.ManagedPtr widget -> widget) -> parent (child event) -> Children child event

  default toChildren :: parent ~ Vector => (Gtk.ManagedPtr widget -> widget) -> parent (child event) -> Children child event
  toChildren _ = Children

-- | All child widgets of a widget, in order. GTK 4 has no
-- @gtk_container_get_children@, so the sibling chain is walked instead.
childWidgets :: (Gtk.IsWidget parent, MonadIO m) => parent -> m (Vector Gtk.Widget)
childWidgets parent = Gtk.widgetGetFirstChild parent >>= go
 where
  go Nothing      = pure Vector.empty
  go (Just child) = Vector.cons child <$> (Gtk.widgetGetNextSibling child >>= go)

-- | The child widget at the given index, if there is one.
childAtIndex
  :: (Gtk.IsWidget parent, MonadIO m) => parent -> Int32 -> m (Maybe Gtk.Widget)
childAtIndex parent i
  | i < 0     = pure Nothing
  | otherwise = (Vector.!? fromIntegral i) <$> childWidgets parent

-- | The index of a child widget among its siblings, if it is there at all.
childIndex
  :: (Gtk.IsWidget parent, Gtk.IsWidget child, MonadIO m)
  => parent
  -> child
  -> m (Maybe Int32)
childIndex parent child = do
  child'   <- Gtk.toWidget child
  children <- childWidgets parent
  pure (fromIntegral <$> Vector.findIndex (== child') children)
