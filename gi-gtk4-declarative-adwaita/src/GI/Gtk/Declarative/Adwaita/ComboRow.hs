{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedLabels      #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}

-- | A declarative @AdwComboRow@: one choice out of more than a few.
--
-- @
-- comboRow [#title := "Level"]
--   defaultComboRowParams
--     { choices  = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
--     , chosen   = Just (levelName state)
--     , onChosen = Just Chose
--     }
-- @
--
-- A combo row is driven by a @GListModel@, which is an object rather
-- than a value, and there is nowhere in a view function to build one.
-- So the choices are described here as data, and this widget keeps the
-- model that goes with them.
--
-- Each choice has a name of its own, which is what says which one is
-- chosen, what 'onChosen' answers with, and what matches one render
-- with the next. The label is what a person reads, and the two are
-- apart because a label is text that changes: a translation, a rename,
-- a number that is formatted another way.
--
-- A row is an @AdwActionRow@, so @#title@, @#subtitle@ and
-- @#useSubtitle@ are ordinary properties of it, and it sits in an
-- @AdwPreferencesGroup@ beside the rows that are already there.
--
-- == This and the toggle group
--
-- 'GI.Gtk.Declarative.Adwaita.ToggleGroup.toggleGroup' is the same
-- question at a smaller size: one choice out of a few, all of them on
-- the screen. Ten choices in a row of toggles is a wide row, and ten
-- in a combo row is a row like any other.
--
-- The two answer 'Nothing' the same way, and for the same reason. A
-- combo row with choices in it always sits on one of them: the
-- selection model libadwaita builds picks the first one by itself, and
-- there is no way through @AdwComboRow@ to ask it not to. So 'chosen'
-- of 'Nothing' leaves the choice to the row rather than emptying it,
-- and a row with no choices at all is the only row on nothing.
--
-- == What a choice does not do
--
-- 'chosen' is a property rather than a command. It is read off the row
-- before it is set, so a row that drifted from what the markup says is
-- put back however it got there. A choice this markup asked for does
-- not come back as an event.
module GI.Gtk.Declarative.Adwaita.ComboRow
  ( ComboRow
  , Choice(..)
  , choice
  , ComboRowParams(..)
  , defaultComboRowParams
  , comboRow
  )
where

import           Control.Exception              ( finally )
import           Control.Monad                  ( unless
                                                , when
                                                )
import           Data.Foldable                  ( for_ )
import           Data.IORef
import           Data.String                    ( IsString(..) )
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Data.Typeable
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified GI.Adw                        as Adw
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Attributes.Collected
import           GI.Gtk.Declarative.Attributes.Internal
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.Widget

-- | One of the choices in a combo row.
data Choice = Choice
  { choiceName  :: Text
  -- ^ Which choice this is. It is what 'chosen' names, what 'onChosen'
  -- answers with, and what matches this choice with the one of the
  -- render before.
  , choiceLabel :: Text
  -- ^ What a person reads in the list.
  }
  deriving (Eq, Show)

-- | A choice with a name and a label.
choice :: Text -> Text -> Choice
choice name theLabel = Choice { choiceName = name, choiceLabel = theLabel }

-- | A choice whose label is its name, which is what a list of numbers
-- or of proper nouns usually is. With @OverloadedStrings@, the markup
-- above writes such a list as @["1", "2", "3"]@.
instance IsString Choice where
  fromString said = choice (Text.pack said) (Text.pack said)

-- | The choices, which one is chosen, and what to do when somebody
-- chooses another.
data ComboRowParams event = ComboRowParams
  { choices  :: Vector Choice
  , chosen   :: Maybe Text
  -- ^ The name of the chosen one. The row is put back to it whenever
  -- the two disagree, so what the markup says is what is on the
  -- screen. 'Nothing' leaves the choice to the row.
  --
  -- A name that is in no choice leaves the row where it is, which is
  -- on the first choice after the list changed under it. A program
  -- that takes a choice away says which of the rest it means, in the
  -- same render.
  , onChosen :: Maybe (Text -> event)
  -- ^ Emitted with the name of the choice somebody made. A choice this
  -- markup asked for does not emit.
  }
  deriving (Functor)

-- | A row with no choices, which emits nothing.
defaultComboRowParams :: ComboRowParams event
defaultComboRowParams = ComboRowParams { choices  = mempty
                                       , chosen   = Nothing
                                       , onChosen = Nothing
                                       }

-- | A declarative combo row. As with the toggle group, the events the
-- markup emits and the events the row is read as are two types with a
-- function between them, so that 'fmap' leaves the state alone.
data ComboRow event where
  ComboRow
    ::Typeable inner
    => Vector (Attribute Adw.ComboRow inner)
    -> ComboRowParams inner
    -> (inner -> event)
    -> ComboRow event

instance Functor ComboRow where
  fmap f (ComboRow attributes params toEvent) =
    ComboRow attributes params (f . toEvent)

-- | A combo row is a widget of its own rather than a widget over
-- something else, so it says how it converts to a 'Widget' itself.
instance FromWidget ComboRow Widget where
  fromWidget = Widget

-- | Construct a combo row from attributes and parameters.
comboRow
  :: (Typeable event, FromWidget ComboRow target)
  => Vector (Attribute Adw.ComboRow event)
  -> ComboRowParams event
  -> target event
comboRow attributes params = fromWidget (ComboRow attributes params id)

--
-- What the row keeps between renders
--

data ComboRowState event = ComboRowState
  { stateChoices  :: IORef (Vector Choice)
  -- ^ The choices the model was built from, in the order they are in.
  -- Their position is what @selected@ counts.
  , stateSink     :: IORef (event -> IO ())
  , stateOnChosen :: IORef (Maybe (Text -> event))
  , stateQuiet    :: IORef Bool
  -- ^ True while this library is the one changing the row. GTK tells a
  -- row about every change, its own included, and a render is not news
  -- to the program that asked for it.
  }

newComboRowState :: ComboRowParams event -> IO (ComboRowState event)
newComboRowState params =
  ComboRowState
    <$> newIORef mempty
    <*> newIORef noSink
    <*> newIORef (onChosen params)
    <*> newIORef False

noSink :: event -> IO ()
noSink _ = pure ()

quietly :: ComboRowState event -> IO a -> IO a
quietly state action = do
  writeIORef (stateQuiet state) True
  action `finally` writeIORef (stateQuiet state) False

--
-- Patchable
--

instance Patchable ComboRow where
  create (ComboRow attributes params _toEvent) = do
    let collected = collectAttributes attributes
    row <- Gtk.new Adw.ComboRow (constructProperties collected)
    updateClasses row mempty (collectedClasses collected)
    slots <- createSlots row attributes
    resolveReferences row attributes

    state <- newComboRowState params
    connectSignals row state
    -- The model and the choice go together and go quietly. Giving a
    -- row a model of its own changes what is selected, and that is
    -- this library talking to itself.
    quietly state $ do
      applyChoices row state (choices params)
      applyChosen row state (chosen params)
    runAfterCreated row attributes

    pure (SomeState (StateTreeWidget (StateTreeNode row collected state slots)))

  patch (SomeState (st :: StateTree stateType w1 c1 e1 cs)) (ComboRow oldAttributes _ _) new@(ComboRow (newAttributes :: Vector (Attribute Adw.ComboRow inner)) newParams _)
    = case (st, eqT @w1 @Adw.ComboRow, eqT @cs @(ComboRowState inner)) of
      (StateTreeWidget top, Just Refl, Just Refl) ->
        let oldCollected      = stateTreeCollectedAttributes top
            newCollected      = collectAttributes newAttributes
            oldCollectedProps = collectedProperties oldCollected
            newCollectedProps = collectedProperties newCollected
        in  if oldCollected `canBeModifiedTo` newCollected
              then Modify $ do
                let row   = stateTreeWidget top
                    state = stateTreeCustomState top
                updateProperties row oldCollectedProps newCollectedProps
                updateOtherProperties row oldCollected newCollected
                updateClasses row
                              (collectedClasses oldCollected)
                              (collectedClasses newCollected)
                slots <- patchSlots row
                                    (stateTreeSlots top)
                                    oldAttributes
                                    newAttributes
                resolveReferences row newAttributes

                writeIORef (stateOnChosen state) (onChosen newParams)
                quietly state $ do
                  applyChoices row state (choices newParams)
                  applyChosen row state (chosen newParams)

                pure
                  (SomeState
                    (StateTreeWidget top
                      { stateTreeCollectedAttributes = newCollected
                      , stateTreeSlots               = slots
                      }
                    )
                  )
              else Replace (create new)
      _ -> Replace (create new)

--
-- EventSource
--

instance EventSource ComboRow where
  subscribe (ComboRow (attributes :: Vector (Attribute Adw.ComboRow inner)) _ toEvent) (SomeState (st :: StateTree stateType w c e cs)) cb
    = case (st, eqT @cs @(ComboRowState inner)) of
      (StateTreeWidget top, Just Refl) -> do
        let state = stateTreeCustomState top
            sink  = cb . toEvent
        writeIORef (stateSink state) sink
        row       <- Gtk.unsafeCastTo Adw.ComboRow (stateTreeWidget top)
        handlers' <- addSignalHandlers sink row attributes
        slots     <- subscribeSlots (stateTreeSlots top) attributes sink
        pure
          (  handlers'
          <> slots
          <> fromCancellation (writeIORef (stateSink state) noSink)
          )
      _ -> pure mempty

--
-- The choices, the choice, and the signal
--

-- | The handler is connected here, once, and what it reports through
-- is read out of the state when it fires. A row that is subscribed
-- twice therefore reports once.
connectSignals :: Adw.ComboRow -> ComboRowState event -> IO ()
connectSignals row state = do
  _ <- Gtk.on row (Gtk.PropertyNotify #selected) $ \_pspec -> do
    quiet <- readIORef (stateQuiet state)
    unless quiet $ do
      position <- Adw.comboRowGetSelected row
      known    <- readIORef (stateChoices state)
      emitted  <- readIORef (stateOnChosen state)
      let name = fmap choiceName (known Vector.!? fromIntegral position)
      for_ ((,) <$> name <*> emitted) $ \(said, make) -> do
        sink <- readIORef (stateSink state)
        sink (make said)
  pure ()

-- | Bring the list the row shows in line with the one asked for.
--
-- A row whose choices are the same names with the same labels keeps
-- the model it has, because building another one takes the selection
-- with it. Anything else is built from the beginning, and the
-- selection is put back by the caller.
applyChoices :: Adw.ComboRow -> ComboRowState event -> Vector Choice -> IO ()
applyChoices row state wanted = do
  before <- readIORef (stateChoices state)
  unless (before == wanted) $ do
    model <- Gtk.stringListNew
      (Just (Vector.toList (fmap choiceLabel wanted)))
    Adw.comboRowSetModel row (Just model)
    writeIORef (stateChoices state) wanted

-- | Put the row back to the choice the markup names, whenever the two
-- disagree.
--
-- This is read before it is written, unlike the commands of the model
-- views, and that is the point of it. A row that somebody has changed
-- says something the markup does not, and the next render is what puts
-- it right, even though the markup says what it said before.
applyChosen :: Adw.ComboRow -> ComboRowState event -> Maybe Text -> IO ()
applyChosen row state wanted = for_ wanted $ \name -> do
  known <- readIORef (stateChoices state)
  for_ (Vector.findIndex ((== name) . choiceName) known) $ \index -> do
    let position = fromIntegral index
    current <- Adw.comboRowGetSelected row
    when (current /= position) (Adw.comboRowSetSelected row position)
