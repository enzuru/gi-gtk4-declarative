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

-- | A declarative @AdwToastOverlay@: the messages a window has to
-- deliver, over whatever it is showing.
--
-- @
-- toastOverlay []
--   (defaultToastOverlayParams theWindowContents)
--     { toasts = [ (toast (messageId m) (messageText m)) { onDismissed = Just (Seen (messageId m)) }
--                | m <- unreadMessages state
--                ]
--     }
-- @
--
-- A toast is a thing that happens rather than a thing that holds, and
-- markup says what holds. So each toast carries a name of its own, and
-- the overlay shows a name it has not shown before. A name that was in
-- the render before is left alone, so a render that happens for some
-- other reason does not say the same thing twice.
--
-- Three messages arriving together are three names, and all three are
-- shown. That is what a single slot cannot say.
--
-- A name is remembered until it leaves 'toasts'. A toast that somebody
-- dismissed, or that timed out, is off the screen while its name is
-- still there, and it is not shown again: to say a thing twice, say it
-- under two names. Numbering them is what an application usually has
-- already, in the identifier of the message it is reporting.
--
-- The overlay shows one toast at a time and holds the rest in a queue,
-- which is libadwaita's own behaviour. Three toasts added together are
-- seen one after another, in the order the vector is in.
--
-- The overlay's child is in the parameters rather than being the child
-- of a 'GI.Gtk.Declarative.Bin.bin', because the toasts are parameters
-- too. An overlay with no toasts to show can still be written
-- @bin Adw.ToastOverlay [] child@.
module GI.Gtk.Declarative.Adwaita.ToastOverlay
  ( ToastOverlay
  , Toast(..)
  , toast
  , ToastOverlayParams(..)
  , defaultToastOverlayParams
  , toastOverlay
  )
where

import           Control.Monad                  ( void )
import           Data.Foldable                  ( for_ )
import           Data.IORef
import           Data.Text                      ( Text )
import           Data.Typeable
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import           Data.Word                      ( Word32 )
import qualified GI.Adw                        as Adw
import qualified GI.Gtk                        as Gtk

import           GI.Gtk.Declarative.Attributes
import           GI.Gtk.Declarative.Attributes.Collected
import           GI.Gtk.Declarative.Attributes.Internal
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.Patch
import           GI.Gtk.Declarative.State
import           GI.Gtk.Declarative.Widget

-- | One message to deliver.
data Toast event = Toast
  { toastKey     :: Text
  -- ^ What tells this message from the others. A name the overlay has
  -- not shown is shown, and a name it has shown is left alone until
  -- the name goes away.
  , toastTitle   :: Text
  , toastButton  :: Maybe (Text, event)
  -- ^ A label, and what pressing it reports. A request to take a move
  -- back is a toast with an accept on it.
  , toastTimeout :: Word32
  -- ^ Seconds. Zero leaves the toast up until somebody dismisses it,
  -- which is what libadwaita means by it.
  , onDismissed  :: Maybe event
  -- ^ Reported when the toast leaves the screen, whether somebody
  -- dismissed it or it timed out.
  }
  deriving (Functor)

-- | A toast with a name and something to say. It has no button, it
-- goes away in libadwaita's own time, and it reports nothing.
toast :: Text -> Text -> Toast event
toast key title = Toast { toastKey     = key
                        , toastTitle   = title
                        , toastButton  = Nothing
                        , toastTimeout = 5
                        , onDismissed  = Nothing
                        }

-- | What the overlay covers, and what it has to say over it.
data ToastOverlayParams event = ToastOverlayParams
  { child  :: Widget event
  , toasts :: Vector (Toast event)
  }
  deriving (Functor)

-- | An overlay over this widget, with nothing to say yet.
defaultToastOverlayParams :: Widget event -> ToastOverlayParams event
defaultToastOverlayParams theChild =
  ToastOverlayParams { child = theChild, toasts = mempty }

-- | A declarative toast overlay. As with the tab view, the events the
-- markup emits and the events the overlay is read as are two types
-- with a function between them, so that 'fmap' leaves the state alone.
data ToastOverlay event where
  ToastOverlay
    ::Typeable inner
    => Vector (Attribute Adw.ToastOverlay inner)
    -> ToastOverlayParams inner
    -> (inner -> event)
    -> ToastOverlay event

instance Functor ToastOverlay where
  fmap f (ToastOverlay attributes params toEvent) =
    ToastOverlay attributes params (f . toEvent)

-- | A toast overlay is a widget of its own rather than a widget over
-- something else, so it says how it converts to a 'Widget' itself.
instance FromWidget ToastOverlay Widget where
  fromWidget = Widget

-- | Construct a toast overlay from attributes and parameters.
toastOverlay
  :: (Typeable event, FromWidget ToastOverlay target)
  => Vector (Attribute Adw.ToastOverlay event)
  -> ToastOverlayParams event
  -> target event
toastOverlay attributes params =
  fromWidget (ToastOverlay attributes params id)

--
-- What the overlay keeps between renders
--

data ToastOverlayState event = ToastOverlayState
  { stateChild :: IORef SomeState
  , stateShown :: IORef (Vector Text)
  -- ^ The names this overlay has shown and not yet forgotten, in the
  -- order they arrived.
  , stateSink  :: IORef (event -> IO ())
  }

noSink :: event -> IO ()
noSink _ = pure ()

--
-- Patchable
--

instance Patchable ToastOverlay where
  create (ToastOverlay attributes params _toEvent) = do
    let collected = collectAttributes attributes
    overlay <- Gtk.new Adw.ToastOverlay (constructProperties collected)
    updateClasses overlay mempty (collectedClasses collected)
    slots <- createSlots overlay attributes
    resolveReferences overlay attributes

    childState <- create (child params)
    Adw.toastOverlaySetChild overlay . Just =<< someStateWidget childState

    state <- ToastOverlayState <$> newIORef childState <*> newIORef mempty <*> newIORef noSink
    showToasts overlay state (toasts params)
    updateOtherProperties overlay mempty collected
    runAfterCreated overlay attributes

    pure
      (SomeState (StateTreeWidget (StateTreeNode overlay collected state slots)))

  patch (SomeState (st :: StateTree stateType w1 c1 e1 cs)) (ToastOverlay oldAttributes oldParams _) new@(ToastOverlay (newAttributes :: Vector (Attribute Adw.ToastOverlay inner)) newParams _)
    = case (st, eqT @w1 @Adw.ToastOverlay, eqT @cs @(ToastOverlayState inner)) of
      (StateTreeWidget top, Just Refl, Just Refl) ->
        let oldCollected      = stateTreeCollectedAttributes top
            newCollected      = collectAttributes newAttributes
            oldCollectedProps = collectedProperties oldCollected
            newCollectedProps = collectedProperties newCollected
        in  if oldCollected `canBeModifiedTo` newCollected
              then Modify $ do
                let overlay = stateTreeWidget top
                    state   = stateTreeCustomState top
                updateProperties overlay oldCollectedProps newCollectedProps
                updateClasses overlay
                              (collectedClasses oldCollected)
                              (collectedClasses newCollected)
                slots <- patchSlots overlay
                                    (stateTreeSlots top)
                                    oldAttributes
                                    newAttributes
                resolveReferences overlay newAttributes
                updateOtherProperties overlay oldCollected newCollected

                patchChild overlay state (child oldParams) (child newParams)
                showToasts overlay state (toasts newParams)

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

-- | Patch the widget under the toasts, the way a bin patches its
-- child.
patchChild
  :: Adw.ToastOverlay
  -> ToastOverlayState event
  -> Widget before
  -> Widget event
  -> IO ()
patchChild overlay state old new = do
  childState <- readIORef (stateChild state)
  case patch childState old new of
    Keep             -> pure ()
    Modify modify    -> writeIORef (stateChild state) =<< modify
    Replace createNew -> do
      made <- createNew
      Adw.toastOverlaySetChild overlay . Just =<< someStateWidget made
      writeIORef (stateChild state) made

--
-- EventSource
--

instance EventSource ToastOverlay where
  subscribe (ToastOverlay (attributes :: Vector (Attribute Adw.ToastOverlay inner)) params toEvent) (SomeState (st :: StateTree stateType w c e cs)) cb
    = case (st, eqT @cs @(ToastOverlayState inner)) of
      (StateTreeWidget top, Just Refl) -> do
        let state = stateTreeCustomState top
            sink  = cb . toEvent
        writeIORef (stateSink state) sink
        overlay   <- Gtk.unsafeCastTo Adw.ToastOverlay (stateTreeWidget top)
        handlers' <- addSignalHandlers sink overlay attributes
        slots     <- subscribeSlots (stateTreeSlots top) attributes sink
        childState <- readIORef (stateChild state)
        below     <- subscribe (child params) childState sink
        pure
          (  handlers'
          <> slots
          <> below
          <> fromCancellation (writeIORef (stateSink state) noSink)
          )
      _ -> pure mempty

--
-- The toasts
--

-- | Show the toasts whose names are new, and forget the names that
-- have gone.
--
-- A name is forgotten when it leaves the markup, so the same name can
-- be shown again later. A name that is still there is left alone,
-- whether its toast is on the screen or somebody dismissed it a minute
-- ago.
showToasts
  :: Adw.ToastOverlay -> ToastOverlayState event -> Vector (Toast event) -> IO ()
showToasts overlay state wanted = do
  shown <- readIORef (stateShown state)
  let names  = fmap toastKey wanted
      kept   = Vector.filter (`Vector.elem` names) shown
      fresh  = Vector.filter ((`Vector.notElem` kept) . toastKey) wanted
  for_ fresh (showToast overlay state)
  writeIORef (stateShown state) (kept <> fmap toastKey fresh)

showToast :: Adw.ToastOverlay -> ToastOverlayState event -> Toast event -> IO ()
showToast overlay state spec = do
  made <- Adw.toastNew (toastTitle spec)
  Adw.toastSetTimeout made (toastTimeout spec)
  for_ (toastButton spec) $ \(theLabel, event) -> do
    Adw.toastSetButtonLabel made (Just theLabel)
    void $ Adw.onToastButtonClicked made (emit state event)
  for_ (onDismissed spec) $ \event ->
    void $ Adw.onToastDismissed made (emit state event)
  -- The overlay takes the toast over, and the value here is not read
  -- again: everything it has to say was said above.
  Adw.toastOverlayAddToast overlay made

emit :: ToastOverlayState event -> event -> IO ()
emit state event = do
  sink <- readIORef (stateSink state)
  sink event
