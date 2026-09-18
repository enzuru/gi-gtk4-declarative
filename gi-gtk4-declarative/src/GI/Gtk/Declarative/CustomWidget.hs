{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | While you can instantiate 'Patchable' and 'EventSource' for your
-- own data types, it's a bit complicated. The 'CustomWidget' data
-- type takes care of some lower-level detail, so that you can focus
-- on the custom behavior of your widget. You still need to think
-- about and implement a patching function, but in an easier way.
module GI.Gtk.Declarative.CustomWidget
  ( CustomPatch(..)
  , CustomWidget(..)
  )
where

import           Data.Typeable
import           Data.Vector                    ( Vector )
import qualified GI.Gtk                        as Gtk
import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Attributes.Collected
import           GI.Gtk.Declarative.Attributes.Internal
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.State

-- | Similar to 'Patch', describing a possible action to perform on a
-- 'Gtk.Widget', decided by 'customPatch'.
data CustomPatch widget internalState
  = CustomReplace
  | CustomModify (widget -> IO internalState)
  -- | Leave the widget's own state as it is.
  --
  -- This is not the same as the 'GI.Gtk.Declarative.Patch.Keep' of a
  -- patch, and a custom widget that answers with it is still patched:
  -- the properties, the classes, the slots and the references of its
  -- attribute list are applied whatever this says, so the patch is a
  -- 'GI.Gtk.Declarative.Patch.Modify'. What this skips is the custom
  -- action, and nothing else.
  | CustomKeep

-- | A custom widget specification, with all functions needed to
-- instantiate 'Patchable' and 'EventSource'. A custom widget:
--
-- * is based on a top 'widget'
-- * can use 'internalState' as a way of keeping an internal state
--   value threaded through updates, which is often useful for passing
--   references to child widgets used in a custom widget
-- * emits events of type 'event'
data CustomWidget widget params internalState event
  = CustomWidget
      { -- | The widget constructor
        customWidget :: Gtk.ManagedPtr widget -> widget,
        -- | Action that creates the initial widget
        customCreate :: params -> IO (widget, internalState),
        -- | Patch function, calculating a 'CustomPatch' based on the state,
        -- old custom data, and new custom data
        customPatch :: params -> params -> internalState -> CustomPatch widget internalState,
        -- | Action that creates an event subscription for the custom widget
        customSubscribe :: params -> internalState -> widget -> (event -> IO ()) -> IO Subscription,
        -- | Declarative 'Attribute's for the custom widget (properties and
        -- classes are handled automatically in patching)
        customAttributes :: Vector (Attribute widget event),
        -- | Parameters passed when constructing the declarative custom widget
        customParams :: params
      }
  deriving (Functor)

instance
  ( Typeable widget,
    Typeable internalState,
    Gtk.IsWidget widget
  ) =>
  Patchable (CustomWidget widget params internalState)
  where

  create custom = do
    (widget, internalState) <- customCreate custom (customParams custom)
    let collected = collectAttributes (customAttributes custom)
    updateProperties widget mempty (collectedProperties collected)
    -- A custom widget is built by its own action rather than from the
    -- construct properties, so what it is held to is set here.
    updateHeldProperties widget (collectedHeld collected)
    updateClasses widget mempty (collectedClasses collected)
    slots <- createSlots widget (customAttributes custom)
    resolveReferences widget (customAttributes custom)
    runAfterCreated widget (customAttributes custom)
    pure
      (SomeState
        (StateTreeWidget (StateTreeNode widget collected internalState slots))
      )

  patch (SomeState (stateTree :: StateTree st w e c cs)) old new =
    case (eqT @cs @internalState, eqT @widget @w) of
      (Just Refl, Just Refl) ->
        let
          oldCollected = stateTreeCollectedAttributes (stateTreeNode stateTree)
          newCollected = collectAttributes (customAttributes new)
          oldCollectedProps = collectedProperties oldCollected
          newCollectedProps = collectedProperties newCollected
          canBeModified = oldCollected `canBeModifiedTo` newCollected
        in
          case
            customPatch new
                        (customParams old)
                        (customParams new)
                        (stateTreeCustomState (stateTreeNode stateTree))
          of
            CustomReplace -> Replace (create new)
            p
              | canBeModified -> Modify $ do
                let widget' = stateTreeNodeWidget stateTree
                updateProperties widget' oldCollectedProps newCollectedProps
                updateHeldProperties widget' (collectedHeld newCollected)
                updateClasses widget'
                              (collectedClasses oldCollected)
                              (collectedClasses newCollected)
                slots <- patchSlots widget'
                                    (stateTreeSlots (stateTreeNode stateTree))
                                    (customAttributes old)
                                    (customAttributes new)
                resolveReferences widget' (customAttributes new)
                let node = stateTreeNode stateTree
                internalState' <- case p of
                  CustomModify f ->
                    f =<< Gtk.unsafeCastTo (customWidget new) widget'
                  CustomKeep    -> pure (stateTreeCustomState node)
                  CustomReplace -> pure (stateTreeCustomState node) -- already handled above
                return
                  (SomeState
                    (StateTreeWidget node
                      { stateTreeCustomState         = internalState'
                      , stateTreeCollectedAttributes = newCollected
                      , stateTreeSlots               = slots
                      }
                    )
                  )
              | otherwise -> Replace (create new)
      _ -> Replace (create new)

instance
  (Typeable internalState, Gtk.GObject widget) =>
  EventSource (CustomWidget widget params internalState)
  where
  subscribe custom (SomeState (stateTree :: StateTree st w e c cs)) cb =
    case eqT @cs @internalState of
      Just Refl -> do
        w' <- Gtk.unsafeCastTo (customWidget custom)
                               (stateTreeNodeWidget stateTree)
        slots' <- subscribeSlots (stateTreeSlots (stateTreeNode stateTree))
                                 (customAttributes custom)
                                 cb
        (slots' <>) <$> customSubscribe custom
                                        (customParams custom)
                                        (stateTreeCustomState
                                          (stateTreeNode stateTree)
                                        )
                                        w'
                                        cb
      Nothing -> pure (fromCancellation (pure ()))
