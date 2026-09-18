{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Internal helpers for applying attributes and signal handlers to GTK+
-- widgets.
module GI.Gtk.Declarative.Attributes.Collected
  ( ClassSet
  , CollectedProperty(..)
  , CollectedProperties
  , HeldProperty(..)
  , HeldProperties
  , Collected(..)
  , canBeModifiedTo
  , constructProperties
  , constructPropertiesOf
  , updateProperties
  , updateHeldProperties
  , updateClasses
  )
where

import qualified Data.GI.Base.Attributes       as GI
import qualified Data.HashMap.Strict           as HashMap
import           Data.HashMap.Strict            ( HashMap )
import           Data.HashSet                   ( HashSet )
import qualified Data.HashSet                  as HashSet
import qualified Data.Set                      as Set
import           Data.Text                      ( Text )
import           Data.Typeable
import           GHC.TypeLits
import qualified GI.Gtk                        as Gtk

-- | A set of CSS classes.
type ClassSet = HashSet Text

-- | A collected property key/value pair, to be used when
-- settings properties when patching widgets.
data CollectedProperty widget where
  CollectedProperty ::( GI.AttrOpAllowed 'GI.AttrConstruct info widget,
      GI.AttrOpAllowed 'GI.AttrSet info widget,
      GI.AttrGetC info widget attr getValue,
      GI.AttrSetTypeConstraint info setValue,
      KnownSymbol attr,
      Typeable attr,
      Eq setValue,
      Typeable setValue
    ) =>
    GI.AttrLabelProxy attr ->
    setValue ->
    CollectedProperty widget

-- | A collected map of key/value pairs, where the type-level property
-- names are represented as 'Text' values. This is used to calculate
-- differences in old and new property sets when patching.
type CollectedProperties widget = HashMap Text (CollectedProperty widget)

-- | A property the widget is held to: one that is read back off the
-- widget and set again whenever the two disagree.
--
-- The value that is read and the value the markup declares are one
-- type here, which is what lets them be compared. An ordinary
-- property has no such constraint, because it is never read.
data HeldProperty widget where
  HeldProperty ::( GI.AttrOpAllowed 'GI.AttrConstruct info widget,
      GI.AttrOpAllowed 'GI.AttrSet info widget,
      GI.AttrGetC info widget attr value,
      GI.AttrSetTypeConstraint info value,
      KnownSymbol attr,
      Typeable attr,
      Eq value,
      Typeable value
    ) =>
    GI.AttrLabelProxy attr ->
    value ->
    HeldProperty widget

type HeldProperties widget = HashMap Text (HeldProperty widget)

-- | Checks if the 'old' collected properties are a subset of the 'new' ones,
-- and thus if a widget thus be updated or if it has to be recreated.
--
-- A property the widget is held to counts here as any other property
-- does, so that a property which changes from one kind to the other
-- goes on being set rather than starting a new widget.
canBeModifiedTo :: Collected widget e1 -> Collected widget e2 -> Bool
old `canBeModifiedTo` new =
  keysOf old `Set.isSubsetOf` keysOf new
 where
  keysOf collected = Set.fromList
    (HashMap.keys (collectedProperties collected)
    <> HashMap.keys (collectedHeld collected)
    )

-- | All the collected properties and classes for a widget. These are based
-- on the 'Attribute' list in the declarative markup, but collected separately
-- into more efficient data structures, optimized for patching.
data Collected widget event
  = Collected
      { collectedClasses :: ClassSet,
        collectedProperties :: CollectedProperties widget,
        collectedHeld :: HeldProperties widget
      }

instance Semigroup (Collected widget event) where
  c1 <> c2 = Collected (collectedClasses c1 <> collectedClasses c2)
                       (collectedProperties c1 <> collectedProperties c2)
                       (collectedHeld c1 <> collectedHeld c2)

instance Monoid (Collected widget event) where
  mempty = Collected mempty mempty mempty

-- | Create a list of GTK construct operations based on collected
-- properties, used when creating new widgets.
constructProperties
  :: forall widget event
   . Collected widget event
  -> [GI.AttrOp widget 'GI.AttrConstruct]
constructProperties collected =
  constructPropertiesOf (collectedProperties collected)
    <> map heldConstructOp (HashMap.elems (collectedHeld collected))
 where
  heldConstructOp :: HeldProperty widget -> GI.AttrOp widget 'GI.AttrConstruct
  heldConstructOp (HeldProperty attr value) = attr Gtk.:= value

-- | As 'constructProperties', for a subset of a widget's properties.
constructPropertiesOf
  :: CollectedProperties widget -> [GI.AttrOp widget 'GI.AttrConstruct]
constructPropertiesOf properties = map
  (\(CollectedProperty attr value) -> attr Gtk.:= value)
  (HashMap.elems properties)

-- | Update the changed properties of a widget, based on the old and new
-- collected properties.
updateProperties
  :: widget -> CollectedProperties widget -> CollectedProperties widget -> IO ()
updateProperties (widget' :: widget) oldProps newProps = do
  let toAdd  = HashMap.elems (HashMap.difference newProps oldProps)
      setOps = mconcat
        (HashMap.elems (HashMap.intersectionWith toMaybeSetOp oldProps newProps)
        )
  GI.set widget' (map (toSetOp (Proxy @widget)) toAdd <> setOps)
 where
  toSetOp
    :: Proxy widget
    -> CollectedProperty widget
    -> Gtk.AttrOp widget 'GI.AttrSet
  toSetOp _ (CollectedProperty attr value) = attr Gtk.:= value
  toMaybeSetOp
    :: CollectedProperty widget
    -> CollectedProperty widget
    -> [Gtk.AttrOp widget 'GI.AttrSet]
  toMaybeSetOp (CollectedProperty attr (v1 :: t1)) (CollectedProperty _ (v2 :: t2))
    = case eqT @t1 @t2 of
      Just Refl | v1 /= v2 -> pure (attr Gtk.:= v2)
      _                    -> mempty

-- | Set the properties the widget is held to, wherever the widget has
-- drifted from what the markup says.
--
-- This is the one place in the library that reads a property back. A
-- property is otherwise compared with what the markup said last time,
-- which is enough until somebody else changes the widget: a person
-- typing in an entry, or clicking a switch. The markup then says what
-- it said before, the comparison finds nothing to do, and what is on
-- the screen is not what the program thinks is there.
updateHeldProperties
  :: forall widget . widget -> HeldProperties widget -> IO ()
updateHeldProperties widget' held = mapM_ hold (HashMap.elems held)
 where
  hold :: HeldProperty widget -> IO ()
  hold (HeldProperty attr value) = do
    current <- GI.get widget' attr
    if current /= value then GI.set widget' [attr Gtk.:= value] else pure ()

-- | Update the widget's CSS classes to only include the new set of
-- classes (last argument).
updateClasses
  :: Gtk.IsWidget widget => widget -> ClassSet -> ClassSet -> IO ()
updateClasses widget' old new = do
  let toAdd    = HashSet.difference new old
      toRemove = HashSet.difference old new
  mapM_ (Gtk.widgetAddCssClass widget')    toAdd
  mapM_ (Gtk.widgetRemoveCssClass widget') toRemove
