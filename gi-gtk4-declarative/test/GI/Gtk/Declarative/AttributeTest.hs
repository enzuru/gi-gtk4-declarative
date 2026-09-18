{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for what an attribute list can hold.
--
-- Three things that the rest of the suite goes around: the CSS classes
-- of a widget, the handlers that are given the widget and answer in
-- 'IO', and what happens to all of them when the markup they are in is
-- mapped into another event type.
--
-- Mapping is how one view function is used inside another, so it is
-- worth knowing that an attribute survives it.
module GI.Gtk.Declarative.AttributeTest where

import           Control.Concurrent.STM
import           Data.IORef
import qualified Data.List                     as List
import           Data.Text                      ( Text )
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           Data.Vector                    ( Vector )
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.MenuModel
import           GI.Gtk.Declarative.ModelView.ColumnView
                                                ( ColumnViewParams(..)
                                                , column
                                                , columnView
                                                , defaultColumnViewParams
                                                )
import qualified GI.Gtk.Declarative.ModelView.ColumnView
                                               as ColumnView
import           GI.Gtk.Declarative.ModelView.ListView
                                                ( ListViewParams(..)
                                                , defaultListViewParams
                                                , listView
                                                )
import qualified GI.Gtk.Declarative.ModelView.ListView
                                               as ListView
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.TestUtils

-- | The events of the markup that is mapped.
data Inner
  = Toggled
  | ToggledWith Text
  | Focused
  | Closing
  deriving (Eq, Show)

-- | The events it is mapped into.
data Outer
  = Inner Inner
  | Other
  deriving (Eq, Show)

-- * CSS classes

-- | The classes of a widget are an attribute like any other, and are
-- applied when it is built.
prop_classes_are_put_on_the_widget = withTests 1 . property $ do
  found <- evalIO $ do
    state <- runUI
      (create (widget Gtk.Label [classes ["one", "two"]] :: Widget Inner))
    List.sort <$> runUI (Gtk.widgetGetCssClasses =<< someStateWidget state)
  found === ["one", "two"]

-- | A patch adds the classes that are new and takes away the ones that
-- are gone, and leaves a class somebody else put there alone.
prop_classes_are_patched = withTests 1 . property $ do
  found <- evalIO $ do
    let first  = widget Gtk.Label [classes ["one", "two"]] :: Widget Inner
        second = widget Gtk.Label [classes ["two", "three"]]
    state   <- runUI (create first)
    widget' <- runUI (someStateWidget state)
    runUI (Gtk.widgetAddCssClass widget' "from-somewhere-else")
    _ <- runUI (patch' state first second)
    List.sort <$> runUI (Gtk.widgetGetCssClasses widget')
  -- GTK keeps the classes in an order of its own, so this is what is
  -- there rather than the order it is in.
  found === ["from-somewhere-else", "three", "two"]

-- * Properties a widget must not drift from

-- | An entry whose text comes from the state, with and without
-- 'holding'.
entrySaying :: Bool -> Text -> Widget Inner
entrySaying held text = widget
  Gtk.Entry
  [if held then holding #text text else #text := text]

-- | Somebody types, and the render that follows says what it said
-- before. An ordinary property is compared with what the markup said
-- last time, so it finds nothing to do, and the entry keeps the
-- typing. This is the failure 'holding' is for, and it is silent.
prop_a_property_that_is_not_held_keeps_what_was_typed =
  withTests 1 . property $ do
    said <- evalIO (typingInto False)
    said === "hello world"

-- | A property the widget is held to is read back off it, so the same
-- render puts the entry where the markup says.
prop_a_held_property_is_put_back_after_typing = withTests 1 . property $ do
  said <- evalIO (typingInto True)
  said === "hello"

-- | Render an entry saying "hello", type into it, patch with markup
-- that says what it said before, and answer with what the entry says.
typingInto :: Bool -> IO Text
typingInto held = do
  let markup = entrySaying held "hello"
  state <- runUI (create markup)
  entry <- runUI (Gtk.unsafeCastTo Gtk.Entry =<< someStateWidget state)
  -- What typing does.
  runUI $ do
    buffer <- Gtk.entryGetBuffer entry
    Gtk.entryBufferSetText buffer "hello world" (-1)
  _ <- runUI (patch' state markup markup)
  runUI (Gtk.get entry #text)

-- | A held property is applied when the widget is built, like any
-- other.
prop_a_held_property_is_set_when_the_widget_is_built =
  withTests 1 . property $ do
    said <- evalIO $ do
      state <- runUI (create (entrySaying True "hello"))
      entry <- runUI (Gtk.unsafeCastTo Gtk.Entry =<< someStateWidget state)
      runUI (Gtk.get entry #text)
    said === "hello"

-- | A held property still follows the markup when the markup changes,
-- which is the ordinary case and must not be broken by the reading.
prop_a_held_property_follows_the_markup = withTests 1 . property $ do
  said <- evalIO $ do
    let first  = entrySaying True "hello"
        second = entrySaying True "goodbye"
    state <- runUI (create first)
    entry <- runUI (Gtk.unsafeCastTo Gtk.Entry =<< someStateWidget state)
    _     <- runUI (patch' state first second)
    runUI (Gtk.get entry #text)
  said === "goodbye"

-- | A switch is the other shape this happens to: somebody clicks it,
-- and the state does not follow.
prop_a_held_switch_is_put_back_after_a_click = withTests 1 . property $ do
  active <- evalIO $ do
    let markup = widget Gtk.Switch [holding #active True] :: Widget Inner
    state  <- runUI (create markup)
    switch <- runUI (Gtk.unsafeCastTo Gtk.Switch =<< someStateWidget state)
    runUI (Gtk.switchSetActive switch False)
    _ <- runUI (patch' state markup markup)
    runUI (Gtk.switchGetActive switch)
  active === True

-- | A property can be held on a widget whose markup changes from one
-- kind of property to the other, rather than the widget being built
-- again.
prop_holding_a_property_that_was_not_held_keeps_the_widget =
  withTests 1 . property $ do
    same <- evalIO $ do
      let first  = entrySaying False "hello"
          second = entrySaying True "hello"
      state  <- runUI (create first)
      before <- runUI (someStateWidget state)
      _      <- runUI (patch' state first second)
      after  <- runUI (someStateWidget state)
      pure (before == after)
    same === True

-- | A container is held to a property in the same way a widget with no
-- children is.
--
-- A container splits its properties into the ones it is built with and
-- the ones that wait for its children, and that split is where the
-- held ones went missing: a container took the attribute, said
-- nothing, and behaved as though it were an ordinary property.
prop_a_container_is_held_to_its_properties = withTests 1 . property $ do
  (drifted, afterPatch) <- evalIO $ do
    let markup =
          container Gtk.Box
                    [holding #sensitive True]
                    [BoxChild defaultBoxChildProperties (widget Gtk.Label [])]
            :: Widget Inner
    state    <- runUI (create markup)
    box      <- runUI (someStateWidget state)
    -- What something outside the markup does.
    runUI (Gtk.widgetSetSensitive box False)
    drifted' <- runUI (Gtk.widgetGetSensitive box)
    _        <- runUI (patch' state markup markup)
    after    <- runUI (Gtk.widgetGetSensitive box)
    pure (drifted', after)
  drifted === False
  afterPatch === True

-- | And it is held from the moment it is built.
prop_a_container_is_held_when_it_is_built = withTests 1 . property $ do
  sensitive <- evalIO $ do
    let markup =
          container Gtk.Box [holding #sensitive False] [] :: Widget Inner
    state <- runUI (create markup)
    runUI (Gtk.widgetGetSensitive =<< someStateWidget state)
  sensitive === False

-- * Every kind of markup, and the properties that need more than
-- setting

-- | A custom widget that takes the attributes it is given, so that it
-- can stand in the table below like the others.
customEntry :: Vector (Attribute Gtk.Entry Inner) -> Widget Inner
customEntry attributes = Widget (CustomWidget { .. })
 where
  customWidget = Gtk.Entry
  customParams = ()
  customAttributes = attributes
  customCreate () = do
    entry <- Gtk.new Gtk.Entry []
    pure (entry, ())
  customPatch :: () -> () -> () -> CustomPatch Gtk.Entry ()
  customPatch _ () () = CustomKeep
  customSubscribe
    :: () -> () -> Gtk.Entry -> (Inner -> IO ()) -> IO Subscription
  customSubscribe () () _entry _cb = pure (fromCancellation (pure ()))

oneRow :: ListViewParams Text Inner
oneRow = (defaultListViewParams (\text -> widget Gtk.Label [#label := text]))
  { ListView.rows = ["one"]
  }

oneCell :: ColumnViewParams Text Inner
oneCell =
  (defaultColumnViewParams
      [column "only" "Only" (\text -> widget Gtk.Label [#label := text])]
    )
    { ColumnView.rows = ["one"]
    }

fileMenu :: Vector (MenuItem Inner)
fileMenu = [subMenu ("File" :: Text) [menuItem ("Quit" :: Text) Toggled]]

-- | One of every kind of markup there is, each holding a property.
--
-- A property that needs more than setting is applied by each kind of
-- markup in its own patch, so a kind that forgets forgets silently.
-- That is not a thought experiment: a container forgot 'holding' for
-- three days, and nothing here noticed, because the tests asked one
-- kind of markup and took its answer for all of them.
heldShapes :: [(Text, Widget Inner)]
heldShapes =
  [ ("a single widget", widget Gtk.Entry [holding #sensitive True])
  , ("a bin"      , bin Gtk.Frame [holding #sensitive True] (widget Gtk.Label []))
  , ("a container", container Gtk.Box [holding #sensitive True] [])
  , ("a custom widget", customEntry [holding #sensitive True])
  , ("a menu bar" , menuBar [holding #sensitive True] fileMenu)
  , ("a list view", listView [holding #sensitive True] oneRow)
  , ("a column view", columnView [holding #sensitive True] oneCell)
  ]

prop_every_kind_of_markup_is_held_to_its_properties =
  withTests 1 . property $ do
    answers <- evalIO (traverse (traverse driftAndPatch) heldShapes)
    answers === map (\(name, _) -> (name, True)) heldShapes

-- | Render, switch the widget off from outside the markup, and patch
-- with the markup that was there before. A held property comes back.
driftAndPatch :: Widget Inner -> IO Bool
driftAndPatch markup = do
  state   <- runUI (create markup)
  widget' <- runUI (someStateWidget state)
  runUI (Gtk.widgetSetSensitive widget' False)
  _ <- runUI (patch' state markup markup)
  runUI (Gtk.widgetGetSensitive widget')

-- | The same kinds, with a property that can be unset.
clearingShapes :: [(Text, Maybe Text -> Widget Inner)]
clearingShapes =
  [ ("a single widget", \t -> widget Gtk.Entry [#tooltipText :=? t])
  , ( "a bin"
    , \t -> bin Gtk.Frame [#tooltipText :=? t] (widget Gtk.Label [])
    )
  , ("a container"    , \t -> container Gtk.Box [#tooltipText :=? t] [])
  , ("a custom widget", \t -> customEntry [#tooltipText :=? t])
  , ("a menu bar"     , \t -> menuBar [#tooltipText :=? t] fileMenu)
  , ("a list view"    , \t -> listView [#tooltipText :=? t] oneRow)
  , ("a column view"  , \t -> columnView [#tooltipText :=? t] oneCell)
  ]

-- | A property that can be unset is unset by 'Nothing', and the widget
-- is the widget it was. Dropping the attribute instead would build it
-- again, and take the keyboard with it.
prop_every_kind_of_markup_can_unset_a_property = withTests 1 . property $ do
  answers <- evalIO (traverse (traverse unsetting) clearingShapes)
  answers === map (\(name, _) -> (name, (Nothing, True))) clearingShapes

unsetting :: (Maybe Text -> Widget Inner) -> IO (Maybe Text, Bool)
unsetting markup = do
  let said    = markup (Just "something is wrong")
      unsaid  = markup Nothing
  state   <- runUI (create said)
  before  <- runUI (someStateWidget state)
  _       <- runUI (patch' state said unsaid)
  after   <- runUI (someStateWidget state)
  tooltip <- runUI (Gtk.widgetGetTooltipText after)
  pure (tooltip, before == after)

-- | And it is set again when the markup says so.
prop_a_property_that_was_unset_can_be_set_again = withTests 1 . property $ do
  tooltip <- evalIO $ do
    let markup t = widget Gtk.Entry [#tooltipText :=? t] :: Widget Inner
    state   <- runUI (create (markup Nothing))
    _       <- runUI (patch' state (markup Nothing) (markup (Just "here")))
    widget' <- runUI (someStateWidget state)
    runUI (Gtk.widgetGetTooltipText widget')
  tooltip === Just "here"

-- * Handlers that are given the widget

-- | An impure handler is given the widget it is on and answers in
-- 'IO', which is what a handler that has to read the widget needs.
prop_an_impure_handler_reads_the_widget = withTests 1 . property $ do
  events <- evalIO $ do
    received <- newTBQueueIO 10
    let markup =
          widget
              Gtk.ToggleButton
              [ #label := ("the label" :: Text)
              , onM #toggled $ \button -> do
                text <- Gtk.buttonGetLabel button
                pure (ToggledWith (maybe "" id text))
              ] :: Widget Inner
    state  <- runUI (create markup)
    button <- runUI (Gtk.unsafeCastTo Gtk.ToggleButton =<< someStateWidget state)
    sub    <- runUI (subscribe markup state (atomically . writeTBQueue received))
    runUI (Gtk.toggleButtonSetActive button True)
    runUI (cancel sub)
    atomically (flushTBQueue received)
  events === [ToggledWith "the label"]

-- | A signal that answers with a 'Bool' takes a handler that says both
-- what to answer and what to emit. A window's close request is the one
-- every application writes.
prop_a_pure_handler_answers_a_signal_that_wants_a_bool =
  withTests 1 . property $ do
    (events, stillThere) <- evalIO
      (closingWindow (\_window -> on #closeRequest (True, Closing)))
    events === [Closing]
    -- The handler answered True, which stops the window closing.
    stillThere === True

prop_an_impure_handler_answers_a_signal_that_wants_a_bool =
  withTests 1 . property $ do
    (events, stillThere) <- evalIO $ closingWindow $ \seen ->
      onM #closeRequest $ \_window -> do
        modifyIORef' seen (+ (1 :: Int))
        pure (True, Closing)
    events === [Closing]
    stillThere === True

-- | Render a window with this attribute on it, ask it to close, and
-- say what it emitted and whether it is still there.
closingWindow
  :: (IORef Int -> Attribute Gtk.Window Inner) -> IO ([Inner], Bool)
closingWindow attribute = do
  received <- newTBQueueIO 10
  seen     <- newIORef 0
  let markup =
        bin Gtk.Window [attribute seen] (widget Gtk.Label []) :: Widget Inner
  state  <- runUI (create markup)
  window <- runUI (Gtk.unsafeCastTo Gtk.Window =<< someStateWidget state)
  sub    <- runUI (subscribe markup state (atomically . writeTBQueue received))
  runUI (Gtk.windowPresent window)
  settle
  runUI (Gtk.windowClose window)
  settle
  visible <- runUI (Gtk.widgetGetVisible window)
  runUI (cancel sub >> Gtk.windowDestroy window)
  events <- atomically (flushTBQueue received)
  pure (events, visible)

-- * Mapping markup into another event type

-- | Markup carrying an attribute of every kind that holds an event,
-- and some that do not.
mapped :: IORef Int -> Widget Outer
mapped ran = Inner <$> inner
 where
  inner :: Widget Inner
  inner = container
    Gtk.Box
    [classes ["mapped"], afterCreated (\_box -> modifyIORef' ran (+ 1))]
    [ BoxChild defaultBoxChildProperties $ widget
      Gtk.ToggleButton
      [#label := ("button" :: Text), on #toggled Toggled]
    , BoxChild defaultBoxChildProperties $ widget
      Gtk.ToggleButton
      [#label := ("impure" :: Text), onM #toggled (\_ -> pure Toggled)]
    , BoxChild defaultBoxChildProperties
      $ widget Gtk.Entry [onFocusEnter Focused]
    , BoxChild defaultBoxChildProperties $ widget Gtk.Entry []
    ]

-- | Every handler in mapped markup emits the mapped event, whether it
-- is a signal or a controller, pure or impure.
prop_mapped_markup_emits_mapped_events = withTests 1 . property $ do
  (events, ranOnce) <- evalIO $ do
    received <- newTBQueueIO 10
    ran      <- newIORef 0
    let markup = mapped ran
    (window, box, sub) <- runUI $ do
      state   <- create markup
      box'    <- someStateWidget state
      window' <- Gtk.new Gtk.Window []
      Gtk.windowSetChild window' (Just box')
      Gtk.windowPresent window'
      sub' <- subscribe markup state (atomically . writeTBQueue received)
      pure (window', box', sub')
    settle
    runUI $ do
      children <- childrenOf box
      case children of
        (first : second : third : fourth : _) -> do
          -- Park the focus away from the entry that reports, so that
          -- what follows does not depend on where GTK put it.
          _      <- Gtk.widgetGrabFocus fourth
          button <- Gtk.unsafeCastTo Gtk.ToggleButton first
          Gtk.toggleButtonSetActive button True
          impure <- Gtk.unsafeCastTo Gtk.ToggleButton second
          Gtk.toggleButtonSetActive impure True
          _      <- Gtk.widgetGrabFocus third
          pure ()
        _ -> fail "the markup did not build what it says it does"
    runUI (cancel sub >> Gtk.windowDestroy window)
    events' <- atomically (flushTBQueue received)
    ran'    <- readIORef ran
    pure (events', ran')
  events === [Inner Toggled, Inner Toggled, Inner Focused]
  -- The action an `afterCreated` carries has no event in it, so
  -- mapping leaves it as it is, and it still runs once.
  ranOnce === 1

-- | Mapping the markup does not lose what is not an event: the
-- properties and the classes are still applied.
prop_mapped_markup_keeps_its_properties = withTests 1 . property $ do
  (labels, cssClasses) <- evalIO $ do
    ran   <- newIORef 0
    state <- runUI (create (mapped ran))
    box   <- runUI (someStateWidget state)
    runUI ((,) <$> descendantLabels box <*> Gtk.widgetGetCssClasses box)
  labels === ["button", "impure"]
  -- A box carries a class of GTK's own for its orientation, so this is
  -- whether the one the markup asked for is there.
  elem "mapped" cssClasses === True

-- | The children of every widget of a widget, which is where the box's
-- children are.
childrenOf :: Gtk.Widget -> IO [Gtk.Widget]
childrenOf parent = go =<< Gtk.widgetGetFirstChild parent
 where
  go Nothing     = pure []
  go (Just next) = (next :) <$> (go =<< Gtk.widgetGetNextSibling next)

tests :: IO Bool
tests = checkParallel $$(discover)
