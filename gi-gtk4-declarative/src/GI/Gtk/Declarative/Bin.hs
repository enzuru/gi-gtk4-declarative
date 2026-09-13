{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedLabels      #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

-- | A declarative representation of a widget with exactly one child.
--
-- GTK 4 removed @GtkBin@, and every widget that holds a single child
-- now has a setter of its own (@gtk_window_set_child@,
-- @gtk_frame_set_child@, and so on.) The 'IsBin' class below names that
-- pair of operations, and the instances in this module are what make a
-- widget usable with 'bin'.
module GI.Gtk.Declarative.Bin
  ( Bin(..)
  , bin
  , IsBin(..)
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
import           GI.Gtk.Declarative.Widget

-- | A widget that holds exactly one child widget, and the two
-- operations needed to patch that child.
class IsBin widget where
  -- | Set (or, with 'Nothing', unset) the child widget. The previous
  -- child, if there was one, is unparented.
  setBinChild :: widget -> Maybe Gtk.Widget -> IO ()
  -- | Get the current child widget, if there is one.
  getBinChild :: widget -> IO (Maybe Gtk.Widget)

instance IsBin Gtk.Window where
  setBinChild = Gtk.windowSetChild
  getBinChild = Gtk.windowGetChild

instance IsBin Gtk.ApplicationWindow where
  setBinChild = Gtk.windowSetChild
  getBinChild = Gtk.windowGetChild

instance IsBin Gtk.Frame where
  setBinChild = Gtk.frameSetChild
  getBinChild = Gtk.frameGetChild

instance IsBin Gtk.AspectFrame where
  setBinChild = Gtk.aspectFrameSetChild
  getBinChild = Gtk.aspectFrameGetChild

instance IsBin Gtk.Button where
  setBinChild = Gtk.buttonSetChild
  getBinChild = Gtk.buttonGetChild

instance IsBin Gtk.ToggleButton where
  setBinChild = Gtk.buttonSetChild
  getBinChild = Gtk.buttonGetChild

instance IsBin Gtk.LinkButton where
  setBinChild = Gtk.buttonSetChild
  getBinChild = Gtk.buttonGetChild

instance IsBin Gtk.CheckButton where
  setBinChild = Gtk.checkButtonSetChild
  getBinChild = Gtk.checkButtonGetChild

instance IsBin Gtk.MenuButton where
  setBinChild = Gtk.menuButtonSetChild
  getBinChild = Gtk.menuButtonGetChild

instance IsBin Gtk.Expander where
  setBinChild = Gtk.expanderSetChild
  getBinChild = Gtk.expanderGetChild

instance IsBin Gtk.Revealer where
  setBinChild = Gtk.revealerSetChild
  getBinChild = Gtk.revealerGetChild

-- | A scrolled window puts a child that does not scroll in a
-- 'Gtk.Viewport' of its own, and 'getBinChild' then answers with that
-- viewport rather than with the child that was set. GTK gives no way
-- of telling a viewport it added from one somebody else did, so this
-- is reported rather than undone.
instance IsBin Gtk.ScrolledWindow where
  setBinChild = Gtk.scrolledWindowSetChild
  getBinChild = Gtk.scrolledWindowGetChild

instance IsBin Gtk.Viewport where
  setBinChild = Gtk.viewportSetChild
  getBinChild = Gtk.viewportGetChild

instance IsBin Gtk.Popover where
  setBinChild = Gtk.popoverSetChild
  getBinChild = Gtk.popoverGetChild

instance IsBin Gtk.ListBoxRow where
  setBinChild = Gtk.listBoxRowSetChild
  getBinChild = Gtk.listBoxRowGetChild

instance IsBin Gtk.FlowBoxChild where
  setBinChild = Gtk.flowBoxChildSetChild
  getBinChild = Gtk.flowBoxChildGetChild

instance IsBin Gtk.SearchBar where
  setBinChild = Gtk.searchBarSetChild
  getBinChild = Gtk.searchBarGetChild

instance IsBin Gtk.WindowHandle where
  setBinChild = Gtk.windowHandleSetChild
  getBinChild = Gtk.windowHandleGetChild

-- | The 'Gtk.Overlay' /main/ child. Widgets drawn on top of it are
-- added with "GI.Gtk.Declarative.Container.Overlay" instead.
instance IsBin Gtk.Overlay where
  setBinChild = Gtk.overlaySetChild
  getBinChild = Gtk.overlayGetChild

-- | Declarative version of a widget with exactly one child.
data Bin widget event where
  Bin
    ::( Typeable widget
       , IsBin widget
       , Gtk.IsWidget widget
       )
    => (Gtk.ManagedPtr widget -> widget)
    -> Vector (Attribute widget event)
    -> Widget event
    -> Bin widget event

instance Functor (Bin widget) where
  fmap f (Bin ctor attrs child) = Bin ctor (fmap f <$> attrs) (fmap f child)

-- | Construct a widget with exactly one child.
bin
  :: ( Typeable widget
     , IsBin widget
     , Gtk.IsWidget widget
     , FromWidget (Bin widget) target
     )
  => (Gtk.ManagedPtr widget -> widget) -- ^ A widget constructor from the underlying gi-gtk library.
  -> Vector (Attribute widget event)   -- ^ List of 'Attribute's.
  -> Widget event                      -- ^ The child widget
  -> target event                      -- ^ The target, whose type is decided by 'FromWidget'.
bin ctor attrs = fromWidget . Bin ctor attrs

--
-- Patchable
--

instance Patchable (Bin parent) where
  create (Bin (ctor :: Gtk.ManagedPtr w -> w) attrs child) = do
    let collected = collectAttributes attrs
    widget' <- Gtk.new ctor (constructProperties collected)
    updateClasses widget' mempty (collectedClasses collected)

    slots       <- createSlots widget' attrs
    resolveReferences widget' attrs
    childState  <- create child
    childWidget <- someStateWidget childState
    setBinChild widget' (Just childWidget)
    runAfterCreated widget' attrs
    return
      (SomeState
        (StateTreeBin (StateTreeNode widget' collected () slots) childState)
      )

  patch (SomeState (st :: StateTree stateType w1 c1 e1 cs)) (Bin _ oldAttributes oldChild) (Bin (ctor :: Gtk.ManagedPtr
      w2
    -> w2) newAttributes newChild)
    = case (st, eqT @w1 @w2) of
      (StateTreeBin top oldChildState, Just Refl) ->
        let
          oldCollected      = stateTreeCollectedAttributes top
          newCollected      = collectAttributes newAttributes
          oldCollectedProps = collectedProperties oldCollected
          newCollectedProps = collectedProperties newCollected
        in
          if oldCollectedProps `canBeModifiedTo` newCollectedProps
            then Modify $ do
              binWidget <- Gtk.unsafeCastTo ctor (stateTreeWidget top)
              updateProperties binWidget oldCollectedProps newCollectedProps
              updateClasses binWidget
                            (collectedClasses oldCollected)
                            (collectedClasses newCollected)
              slots <- patchSlots binWidget
                                  (stateTreeSlots top)
                                  oldAttributes
                                  newAttributes
              resolveReferences binWidget newAttributes

              let top' = top { stateTreeCollectedAttributes = newCollected
                             , stateTreeSlots               = slots
                             }
              case patch oldChildState oldChild newChild of
                Modify  modify    -> SomeState . StateTreeBin top' <$> modify
                Replace createNew -> do
                  newChildState <- createNew
                  childWidget   <- someStateWidget newChildState
                  -- Setting the new child unparents the old one.
                  setBinChild binWidget (Just childWidget)
                  return (SomeState (StateTreeBin top' newChildState))
                Keep -> return (SomeState st)
            else Replace (create (Bin ctor newAttributes newChild))
      _ -> Replace (create (Bin ctor newAttributes newChild))

--
-- EventSource
--

instance EventSource (Bin parent) where
  subscribe (Bin ctor props child) (SomeState st) cb = case st of
    StateTreeBin top childState -> do
      binWidget <- Gtk.unsafeCastTo ctor (stateTreeWidget top)
      handlers' <- addSignalHandlers cb binWidget props
      slots'    <- subscribeSlots (stateTreeSlots top) props cb
      (<> (handlers' <> slots')) <$> subscribe child childState cb
    _ -> error "Cannot subscribe to Bin events with a non-bin state tree."

instance a ~ b => FromWidget (Bin a) (Bin b) where
  fromWidget = id
