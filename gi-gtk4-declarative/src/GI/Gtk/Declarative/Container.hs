{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

-- | Implementations for widgets with zero or more children.
module GI.Gtk.Declarative.Container
  ( Container
  , container
  , Children
  , ToChildren(..)
  )
where

import           Control.Monad                  ( forM
                                                , unless
                                                )
import qualified Data.HashMap.Strict           as HashMap
import           Data.Text                      ( Text )
import           Data.Typeable
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified GI.Gtk                        as Gtk
import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Attributes.Collected
import           GI.Gtk.Declarative.Attributes.Internal
import           GI.Gtk.Declarative.Container.Class
import           GI.Gtk.Declarative.Container.Patch
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.Widget

-- | Declarative version of a /container/ widget, i.e. a widget with zero
-- or more child widgets. The type of 'children' is parameterized, and differs
-- across the supported container widgets, as some containers require specific
-- types of child widgets. These type relations are decided by 'IsContainer',
-- and instances can found in "GI.Gtk.Declarative.Container.Patch".
data Container widget children event where
  Container ::( Typeable widget,
      Gtk.IsWidget widget,
      Functor children
    ) =>
    (Gtk.ManagedPtr widget -> widget) ->
    Vector (Attribute widget event) ->
    children event ->
    Container widget children event

instance Functor (Container widget children) where
  fmap f (Container ctor attrs children) =
    Container ctor (fmap f <$> attrs) (fmap f children)

-- | Construct a /container/ widget, i.e. a widget with zero or more children.
container
  :: ( Typeable widget
     , Functor child
     , Gtk.IsWidget widget
     , FromWidget (Container widget (Children child)) target
     , ToChildren widget parent child
     )
  => 
  -- | A container widget constructor from the underlying gi-gtk library.
     (Gtk.ManagedPtr widget -> widget)
  ->
  -- | 'Attribute's.
     Vector (Attribute widget event)
  ->
  -- | The container's 'child' widgets, in a 'MarkupOf' builder.
     parent (child event)
  ->
  -- | The target, whose type is decided by 'FromWidget'.
     target event
container ctor attrs = fromWidget . Container ctor attrs . toChildren ctor

--
-- Deferred properties
--

-- | The properties that only take once the container has its children,
-- and the ones that do not. A stack's @visibleChildName@ is the first
-- kind: naming a child the container does not hold yet is a warning
-- from GTK and then nothing.
deferredProps, immediateProps
  :: [Text] -> CollectedProperties widget -> CollectedProperties widget
deferredProps deferred =
  HashMap.filterWithKey (\name _ -> name `elem` deferred)
immediateProps deferred =
  HashMap.filterWithKey (\name _ -> name `notElem` deferred)

--
-- Patchable
--

instance
  (Patchable child, Typeable child, IsContainer container child) =>
  Patchable (Container container (Children child))
  where

  create (Container (ctor :: Gtk.ManagedPtr w -> w) attrs children) = do
    let collected = collectAttributes attrs
        deferred  = deferredProperties (Proxy :: Proxy w)
        properties = collectedProperties collected
        later = deferredProps deferred properties
        now   = immediateProps deferred properties
    widget' <- Gtk.new ctor (constructPropertiesOf now)
    updateClasses widget' mempty (collectedClasses collected)
    slots       <- createSlots widget' attrs
    resolveReferences widget' attrs
    childStates <- forM (unChildren children) $ \child -> do
      childState <- create child
      appendChild widget' child =<< someStateWidget childState
      return childState
    -- The deferred properties name children, so they are set now that
    -- the children are there.
    unless (HashMap.null later) $ updateProperties widget' mempty later
    -- A container's properties are split into the ones it is built with
    -- and the ones that wait for its children, so what it is held to is
    -- set here rather than at construction, with the rest of the
    -- waiting ones.
    updateHeldProperties widget' (collectedHeld collected)
    runAfterCreated widget' attrs
    return
      (SomeState
        (StateTreeContainer (StateTreeNode widget' collected () slots)
                            childStates
        )
      )

  patch (SomeState (st :: StateTree stateType w1 c1 e1 cs)) (Container _ oldAttributes oldChildren) new@(Container (ctor :: Gtk.ManagedPtr
      w2
    -> w2) newAttributes (newChildren :: Children c2 e2))
    = let
        -- Worked out here rather than below, because matching on the
        -- state tree brings a second 'IsContainer' constraint into
        -- scope, and GHC cannot then tell which of the two this
        -- belongs to.
        deferred = deferredProperties (Proxy :: Proxy w2)
      in
        case (st, eqT @w1 @w2) of
          (StateTreeContainer top childStates, Just Refl) ->
            let oldCollected      = stateTreeCollectedAttributes top
                newCollected      = collectAttributes newAttributes
                oldCollectedProps = collectedProperties oldCollected
                newCollectedProps = collectedProperties newCollected
            in  if oldCollected `canBeModifiedTo` newCollected
                  then Modify $ do
                    containerWidget <- Gtk.unsafeCastTo ctor (stateTreeWidget top)
                    updateProperties containerWidget
                                     (immediateProps deferred oldCollectedProps)
                                     (immediateProps deferred newCollectedProps)
                    updateClasses containerWidget
                                  (collectedClasses oldCollected)
                                  (collectedClasses newCollected)
                    slots <- patchSlots containerWidget
                                        (stateTreeSlots top)
                                        oldAttributes
                                        newAttributes
                    resolveReferences containerWidget newAttributes
                    let top' = top { stateTreeCollectedAttributes = newCollected
                                   , stateTreeSlots               = slots
                                   }
                    patched <- patchInContainer
                      (StateTreeContainer top' childStates)
                      containerWidget
                      (unChildren oldChildren)
                      (unChildren newChildren)
                    -- The deferred properties name children, so they are
                    -- set now that this patch has put the children there.
                    -- A stack that is told to show a child in the same
                    -- patch that adds it would otherwise be told before
                    -- the child was there, which GTK reports as a warning
                    -- and then ignores.
                    let later = deferredProps deferred newCollectedProps
                    unless (HashMap.null later) $ updateProperties
                      containerWidget
                      (deferredProps deferred oldCollectedProps)
                      later
                    -- What the container is held to, after the children
                    -- are there, for the same reason as the deferred
                    -- properties above.
                    updateHeldProperties containerWidget
                                         (collectedHeld newCollected)
                    pure (SomeState patched)
                  else Replace (create new)
          _ -> Replace (create new)

--
-- EventSource
--

instance
  EventSource child =>
  EventSource (Container widget (Children child))
  where
  subscribe (Container ctor props children) (SomeState st) cb = case st of
    StateTreeContainer top childStates -> do
      parentWidget <- Gtk.unsafeCastTo ctor (stateTreeWidget top)
      handlers' <- addSignalHandlers cb parentWidget props
      slots'    <- subscribeSlots (stateTreeSlots top) props cb
      subs <- flip foldMap (Vector.zip (unChildren children) childStates)
        $ \(c, childState) -> subscribe c childState cb
      return (handlers' <> slots' <> subs)
    _ ->
      error
        "Warning: Cannot subscribe to Container events with a non-container state tree."

--
-- FromWidget
--

-- Overlapping, and picked over the general instance in
-- "GI.Gtk.Declarative.Widget", which also matches a container. Both
-- wrap the value in a 'Widget', so which one is picked only decides
-- which constraints are asked for.
instance
  {-# OVERLAPPING #-}
  ( Typeable widget,
    Typeable children,
    Patchable (Container widget children),
    EventSource (Container widget children)
  ) =>
  FromWidget (Container widget children) Widget
  where
  fromWidget = Widget

instance a ~ b => FromWidget (Container a children) (Container b children) where
  fromWidget = id
