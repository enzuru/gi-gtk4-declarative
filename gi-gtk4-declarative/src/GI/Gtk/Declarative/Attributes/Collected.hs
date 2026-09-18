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
  , MaybeProperty(..)
  , MaybeProperties
  , Collected(..)
  , canBeModifiedTo
  , constructProperties
  , constructPropertiesOf
  , updateProperties
  , updateOtherProperties
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

-- | A property that can be unset, and the value it has or has not.
--
-- Dropping a property from the attribute list builds the widget again,
-- because most properties cannot be unset. One that can says so with
-- 'Nothing' instead, and stays in the list.
data MaybeProperty widget where
  MaybeProperty ::( GI.AttrOpAllowed 'GI.AttrConstruct info widget,
      GI.AttrOpAllowed 'GI.AttrSet info widget,
      GI.AttrClearC info widget attr,
      GI.AttrSetTypeConstraint info setValue,
      KnownSymbol attr,
      Typeable attr,
      Eq setValue,
      Typeable setValue
    ) =>
    GI.AttrLabelProxy attr ->
    Maybe setValue ->
    MaybeProperty widget

type MaybeProperties widget = HashMap Text (MaybeProperty widget)

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
    (  HashMap.keys (collectedProperties collected)
    <> HashMap.keys (collectedHeld collected)
    <> HashMap.keys (collectedMaybe collected)
    )

-- | All the collected properties and classes for a widget. These are based
-- on the 'Attribute' list in the declarative markup, but collected separately
-- into more efficient data structures, optimized for patching.
data Collected widget event
  = Collected
      { collectedClasses :: ClassSet,
        collectedProperties :: CollectedProperties widget,
        collectedHeld :: HeldProperties widget,
        collectedMaybe :: MaybeProperties widget
      }

instance Semigroup (Collected widget event) where
  c1 <> c2 = Collected (collectedClasses c1 <> collectedClasses c2)
                       (collectedProperties c1 <> collectedProperties c2)
                       (collectedHeld c1 <> collectedHeld c2)
                       (collectedMaybe c1 <> collectedMaybe c2)

instance Monoid (Collected widget event) where
  mempty = Collected mempty mempty mempty mempty

-- | Create a list of GTK construct operations based on collected
-- properties, used when creating new widgets.
constructProperties
  :: forall widget event
   . Collected widget event
  -> [GI.AttrOp widget 'GI.AttrConstruct]
constructProperties collected =
  constructPropertiesOf (collectedProperties collected)
    <> map heldConstructOp (HashMap.elems (collectedHeld collected))
    <> concatMap maybeConstructOp (HashMap.elems (collectedMaybe collected))
 where
  heldConstructOp :: HeldProperty widget -> GI.AttrOp widget 'GI.AttrConstruct
  heldConstructOp (HeldProperty attr value) = attr Gtk.:= value
  -- A property that is not set is the widget's own default, which for
  -- a property that can be unset is the unset one.
  maybeConstructOp
    :: MaybeProperty widget -> [GI.AttrOp widget 'GI.AttrConstruct]
  maybeConstructOp (MaybeProperty attr value) =
    maybe [] (\v -> [attr Gtk.:= v]) value

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

-- | Apply the properties that need more than a comparison of what the
-- markup said: the ones the widget is held to, and the ones that can
-- be unset.
--
-- Every widget calls this where it calls 'updateProperties', and one
-- call rather than two is deliberate: a widget that forgets it forgets
-- both, silently, which is how a container came to drop 'holding' on
-- the floor once already.
updateOtherProperties
  :: widget -> Collected widget e1 -> Collected widget e2 -> IO ()
updateOtherProperties widget' old new = do
  updateHeldProperties widget' (collectedHeld new)
  updateMaybeProperties widget' (collectedMaybe old) (collectedMaybe new)

-- | Set or unset the properties that can be unset, wherever the markup
-- says something else than it said last time.
updateMaybeProperties
  :: forall widget
   . widget
  -> MaybeProperties widget
  -> MaybeProperties widget
  -> IO ()
updateMaybeProperties widget' old new = mapM_ apply
                                              (HashMap.toList new)
 where
  apply :: (Text, MaybeProperty widget) -> IO ()
  apply (key, property@(MaybeProperty attr value)) =
    case HashMap.lookup key old of
      Just before | same before property -> pure ()
      _                                  -> case value of
        Just set' -> GI.set widget' [attr Gtk.:= set']
        Nothing   -> GI.clear widget' attr
  same :: MaybeProperty widget -> MaybeProperty widget -> Bool
  same (MaybeProperty _ (v1 :: Maybe t1)) (MaybeProperty _ (v2 :: Maybe t2)) =
    case eqT @t1 @t2 of
      Just Refl -> v1 == v2
      Nothing   -> False

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
