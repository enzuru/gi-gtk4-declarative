{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

-- | Declarative menus.
--
-- GTK 4 removed @GtkMenu@, @GtkMenuBar@, and @GtkMenuItem@. A menu is
-- now a 'GI.Gio.Objects.Menu.Menu' model of labels and action names,
-- shown by a widget such as 'Gtk.PopoverMenuBar' or 'Gtk.MenuButton'.
--
-- This module keeps the declarative style of the rest of the library:
-- you describe the menu as a tree of 'MenuItem' values that carry
-- events, and the actions behind them are created, named, and wired to
-- the event callback for you.
module GI.Gtk.Declarative.MenuModel
  ( MenuItem(..)
  , menuItem
  , subMenu
  , menuSection
  , menuBar
  , menuButton
  , MenuWidget(..)
  , IsMenuHolder(..)
  )
where

import           Control.Monad                  ( foldM )
import           Data.Foldable                  ( for_ )
import           Data.IORef
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Data.Typeable
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified GI.Gio                        as Gio
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Attributes.Collected
import           GI.Gtk.Declarative.Attributes.Internal
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.Widget

-- | An item in a declarative menu.
data MenuItem event
  = MenuItem Text event
  -- ^ A menu item with a label, emitting an event when it is activated.
  | SubMenu Text (Vector (MenuItem event))
  -- ^ A labelled menu nested in another menu.
  | MenuSection (Maybe Text) (Vector (MenuItem event))
  -- ^ A group of items, separated from its neighbours, with an
  -- optional heading.
  deriving (Functor)

-- | A menu item with a label, emitting an event when it is activated.
menuItem :: Text -> event -> MenuItem event
menuItem = MenuItem

-- | A labelled menu nested in another menu.
subMenu :: Text -> Vector (MenuItem event) -> MenuItem event
subMenu = SubMenu

-- | A group of items, separated from its neighbours, with an optional
-- heading.
menuSection :: Maybe Text -> Vector (MenuItem event) -> MenuItem event
menuSection = MenuSection

-- | A widget that shows a menu model.
class IsMenuHolder widget where
  setMenuModel :: widget -> Maybe Gio.MenuModel -> IO ()

instance IsMenuHolder Gtk.PopoverMenuBar where
  setMenuModel = Gtk.popoverMenuBarSetMenuModel

instance IsMenuHolder Gtk.MenuButton where
  setMenuModel = Gtk.menuButtonSetMenuModel

-- | A declarative widget showing a menu.
data MenuWidget widget event where
  MenuWidget
    ::( Typeable widget
       , Gtk.IsWidget widget
       , IsMenuHolder widget
       )
    => (Gtk.ManagedPtr widget -> widget)
    -> Vector (Attribute widget event)
    -> Vector (MenuItem event)
    -> MenuWidget widget event

instance Functor (MenuWidget widget) where
  fmap f (MenuWidget ctor attrs items) =
    MenuWidget ctor (fmap f <$> attrs) (fmap f <$> items)

-- | Construct a menu bar, i.e. a 'Gtk.PopoverMenuBar' showing the
-- given items.
menuBar
  :: FromWidget (MenuWidget Gtk.PopoverMenuBar) target
  => Vector (Attribute Gtk.PopoverMenuBar event)
  -> Vector (MenuItem event)
  -> target event
menuBar attrs = fromWidget . MenuWidget Gtk.PopoverMenuBar attrs

-- | Construct a 'Gtk.MenuButton', i.e. a button that pops up the given
-- menu when it is clicked.
menuButton
  :: FromWidget (MenuWidget Gtk.MenuButton) target
  => Vector (Attribute Gtk.MenuButton event)
  -> Vector (MenuItem event)
  -> target event
menuButton attrs = fromWidget . MenuWidget Gtk.MenuButton attrs

--
-- Internal state
--

-- | The shape of a menu, without the events. Two menus with the same
-- shape are shown by the same menu model, so patching only has to
-- rebuild the model when this changes.
data MenuShape
  = ItemShape Text
  | SubMenuShape Text [MenuShape]
  | SectionShape (Maybe Text) [MenuShape]
  deriving (Eq, Show)

-- | What a rendered menu keeps between patches: the shape it was built
-- from, and the callback its actions dispatch through.
data MenuState = MenuState
  { menuShape    :: [MenuShape]
  , menuDispatch :: IORef (Int -> IO ())
  }

shapeOf :: Vector (MenuItem event) -> [MenuShape]
shapeOf = map shapeOfItem . Vector.toList
 where
  shapeOfItem = \case
    MenuItem label _        -> ItemShape label
    SubMenu  label items    -> SubMenuShape label (shapeOf items)
    MenuSection label items -> SectionShape label (shapeOf items)

-- | The events of all the items that can be activated, in the order
-- the actions behind them are numbered.
leafEvents :: Vector (MenuItem event) -> Vector event
leafEvents = Vector.concatMap $ \case
  MenuItem _ event  -> Vector.singleton event
  SubMenu  _ items  -> leafEvents items
  MenuSection _ items -> leafEvents items

-- | The action group the menu's actions live in.
actionPrefix :: Text
actionPrefix = "menu"

actionName :: Int -> Text
actionName i = "item" <> Text.pack (show i)

-- | Build the menu model and the actions behind it, and hand both to
-- the widget. Returns the number of activatable items.
buildMenu
  :: (Gtk.IsWidget widget, IsMenuHolder widget)
  => widget
  -> IORef (Int -> IO ())
  -> Vector (MenuItem event)
  -> IO Int
buildMenu widget' dispatch items = do
  model <- Gio.menuNew
  group <- Gio.simpleActionGroupNew
  count <- addItems model group dispatch 0 items
  Gtk.widgetInsertActionGroup widget' actionPrefix (Just group)
  setMenuModel widget' . Just =<< Gio.toMenuModel model
  pure count

addItems
  :: Gio.Menu
  -> Gio.SimpleActionGroup
  -> IORef (Int -> IO ())
  -> Int
  -> Vector (MenuItem event)
  -> IO Int
addItems model group dispatch = foldM addItem
 where
  addItem next = \case
    MenuItem label _ -> do
      action <- Gio.simpleActionNew (actionName next) Nothing
      _      <- Gio.onSimpleActionActivate action $ \_parameter -> do
        dispatch' <- readIORef dispatch
        dispatch' next
      Gio.actionMapAddAction group action
      Gio.menuAppend model
                     (Just label)
                     (Just (actionPrefix <> "." <> actionName next))
      pure (next + 1)
    SubMenu label items -> do
      sub   <- Gio.menuNew
      next' <- addItems sub group dispatch next items
      Gio.menuAppendSubmenu model (Just label) sub
      pure next'
    MenuSection label items -> do
      sub   <- Gio.menuNew
      next' <- addItems sub group dispatch next items
      Gio.menuAppendSection model label sub
      pure next'

--
-- Patchable
--

instance Patchable (MenuWidget widget) where
  create (MenuWidget (ctor :: Gtk.ManagedPtr w -> w) attrs items) = do
    let collected = collectAttributes attrs
    widget'  <- Gtk.new ctor (constructProperties collected)
    updateClasses widget' mempty (collectedClasses collected)
    dispatch <- newIORef (const (pure ()))
    _        <- buildMenu widget' dispatch items
    slots <- createSlots widget' attrs
    let state = MenuState { menuShape = shapeOf items, menuDispatch = dispatch }
    pure
      (SomeState (StateTreeWidget (StateTreeNode widget' collected state slots)))

  patch (SomeState (st :: StateTree stateType w1 c1 e1 cs)) (MenuWidget _ oldAttributes _) new@(MenuWidget (_ctor :: Gtk.ManagedPtr
      w2
    -> w2) newAttributes newItems)
    = case (st, eqT @w1 @w2, eqT @cs @MenuState) of
      (StateTreeWidget top, Just Refl, Just Refl) ->
        let oldCollected      = stateTreeCollectedAttributes top
            newCollected      = collectAttributes newAttributes
            oldCollectedProps = collectedProperties oldCollected
            newCollectedProps = collectedProperties newCollected
            oldState          = stateTreeCustomState top
            newShape          = shapeOf newItems
        in  if oldCollectedProps `canBeModifiedTo` newCollectedProps
              then Modify $ do
                let widget' = stateTreeWidget top
                updateProperties widget' oldCollectedProps newCollectedProps
                updateClasses widget'
                              (collectedClasses oldCollected)
                              (collectedClasses newCollected)
                -- The events of the new items are picked up when the
                -- new markup is subscribed to; only a change of shape
                -- needs a new model.
                slots    <- patchSlots widget'
                                       (stateTreeSlots top)
                                       oldAttributes
                                       newAttributes
                newState <- if menuShape oldState == newShape
                  then pure oldState
                  else do
                    _ <- buildMenu widget' (menuDispatch oldState) newItems
                    pure oldState { menuShape = newShape }
                pure
                  (SomeState
                    (StateTreeWidget top
                      { stateTreeCollectedAttributes = newCollected
                      , stateTreeCustomState         = newState
                      , stateTreeSlots               = slots
                      }
                    )
                  )
              else Replace (create new)
      _ -> Replace (create new)

--
-- EventSource
--

instance EventSource (MenuWidget widget) where
  subscribe (MenuWidget ctor attrs items) (SomeState (st :: StateTree stateType w child event cs)) cb
    = case (st, eqT @cs @MenuState) of
      (StateTreeWidget top, Just Refl) -> do
        let state  = stateTreeCustomState top
            events = leafEvents items
        writeIORef (menuDispatch state)
                   (\i -> for_ (events Vector.!? i) cb)
        widget'  <- Gtk.unsafeCastTo ctor (stateTreeWidget top)
        handlers <- foldMap (addSignalHandler cb widget') attrs
        slots'   <- subscribeSlots (stateTreeSlots top) attrs cb
        pure
          (  handlers
          <> slots'
          <> fromCancellation
               (writeIORef (menuDispatch state) (const (pure ())))
          )
      _ -> pure mempty
