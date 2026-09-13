-- The `Gtk.IsWindow window` constraints below are the ones a gi-gtk
-- user writes; GHC would rather they were spelled out as descendant
-- constraints, which would say the same thing less clearly.
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE TypeApplications #-}

-- | A simple application architecture style inspired by PureScript's Pux
-- framework.
module GI.Gtk.Declarative.App.Simple
  ( App(..)
  , AppView
  , Transition(..)
  , run
  , runLoop
  , runInApplication
  , startInApplication
  )
where

import           Control.Concurrent
import qualified Control.Concurrent.Async      as Async
import           Control.Exception              ( SomeException,
                                                  Exception,
                                                  catch,
                                                  finally,
                                                  throwIO)
import           Control.Monad
import           Data.Foldable                  ( for_ )
import           Data.IORef
import           Data.Typeable
import qualified GI.GLib                       as GLib
import qualified GI.Gio                        as Gio
import qualified GI.Gtk                        as Gtk
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.State
import           Pipes
import qualified Pipes.Prelude                 as Pipes
import           Pipes.Concurrent
import           System.Exit
import           System.IO

-- | Describes an state reducer application.
data App window state event =
  App
    { update       :: state -> event -> Transition state event
    -- ^ The update function of an application reduces the current state and
    -- a new event to a 'Transition', which decides if and how to transition
    -- to the next state.
    , view         :: state -> AppView window event
    -- ^ The view renders a state value as a window, parameterized by the
    -- 'App's event type.
    , inputs       :: [Producer event IO ()]
    -- ^ Inputs are pipes 'Producer's that feed events into the application.
    , initialState :: state
    -- ^ The initial state value of the state reduction loop.
    }

-- | The top-level widget for the 'view' function of an 'App',
-- requiring a GTK 'Gtk.Window'.
type AppView window event = Bin window event

-- | The result of applying the 'update' function, deciding if and how to
-- transition to the next state.
data Transition state event =
  -- Transition to the given state, and with an IO action that may return a
  -- new event.
  Transition state (IO (Maybe event))
  -- | Exit the application.
  | Exit

-- | An exception thrown by the 'run' function when the GLib main loop
-- exits before event/state handling, which should never happen but can
-- be caused by user code quitting the loop.
data GtkMainExitedException =
  GtkMainExitedException String deriving (Typeable, Show)

instance Exception GtkMainExitedException

-- | Initialize GTK and run the application in it. This is a
-- convenience function that is highly recommended. If you need more
-- flexibility, e.g. to set up GTK yourself, use 'runLoop' instead.
run
  :: (IsBin window, Gtk.IsWindow window)
  => App window state event      -- ^ Application to run
  -> IO state
run app = do
  assertRuntimeSupportsBoundThreads
  Gtk.init

  -- If any exception happen in `runLoop`, it will be re-thrown here
  -- and the application will be killed.
  mainLoop <- GLib.mainLoopNew Nothing False
  main     <- Async.async (GLib.mainLoopRun mainLoop)
  runLoop app `finally` (GLib.mainLoopQuit mainLoop >> Async.wait main)

-- | Run an 'App'. This IO action will loop, so run it in a separate thread
-- using 'async' if you're calling it before the GTK main loop.
-- Note: the following example take care of exception raised in 'runLoop'.
--
-- @
--     Gtk.init
--     mainLoop <- GLib.mainLoopNew Nothing False
--     main <- Async.async (GLib.mainLoopRun mainLoop)
--     runLoop app `finally` (GLib.mainLoopQuit mainLoop >> Async.wait main)
-- @
runLoop
  :: (IsBin window, Gtk.IsWindow window)
  => App window state event
  -> IO state
runLoop = runLoopIn Nothing

-- | Run an 'App' inside a 'Gtk.Application' somebody else started.
--
-- A program that needs an application of its own, for its identifier,
-- its actions, its accelerators, or the file named on its command line,
-- cannot use 'run', which makes a main loop of its own, and cannot use
-- 'runLoop', which never tells the application about its window. An
-- application holding no window quits as soon as @activate@ returns,
-- so the window has to be registered.
--
-- This registers the window it makes, registers the new one when a
-- patch replaces it, and takes the window down when the loop ends, so
-- that an application holding no other window quits on its own. It
-- neither initializes GTK nor makes a main loop: the application does
-- both.
--
-- It loops until the application exits, so it cannot be called from
-- the @activate@ handler directly. Use 'startInApplication', which
-- starts it in a thread of its own and holds the application while it
-- gets going. Starting it any other way is the mistake described
-- there.
runInApplication
  :: (IsBin window, Gtk.IsWindow window, Gtk.IsApplication app)
  => app
  -> App window state event
  -> IO state
runInApplication application app = do
  application' <- Gtk.toApplication application
  runLoopIn (Just application') app

-- | Start an 'App' from an application's @activate@ handler.
--
-- @
-- main :: IO ()
-- main = do
--   application <- Gtk.applicationNew (Just "com.example.App") []
--   _ <- Gtk.on application #activate (void (startInApplication application app))
--   void $ Gio.applicationRun application Nothing
-- @
--
-- An application quits as soon as @activate@ returns holding no window,
-- and the window here is built on the main loop a moment later, so this
-- holds the application until the loop ends. Without that hold the
-- application would be gone before its window arrived.
--
-- It answers with the loop it started, which a caller with something to
-- take down when the window closes waits on:
--
-- @
-- _ <- Gtk.on application #activate $ do
--   loop <- startInApplication application app
--   void . Async.async $ do
--     _ <- Async.wait loop
--     stopTheKernel
-- @
--
-- Waiting on it in the @activate@ handler itself would stop the main
-- loop before it started, so the waiting goes in a thread of its own.
-- A caller with nothing to take down ignores the answer.
--
-- Starting the loop by hand, with 'runInApplication' in a thread of
-- your own and no hold on the application, does not fail where you
-- wrote it. The application returns from @activate@ holding no window
-- and quits, and what you get is
--
-- > Gtk-CRITICAL **: New application windows must be added after the
-- > GApplication::startup signal has been emitted
--
-- followed by a window that never appears.
startInApplication
  :: (IsBin window, Gtk.IsWindow window, Gtk.IsApplication app)
  => app
  -> App window state event
  -> IO (Async.Async state)
startInApplication application app = do
  application' <- Gtk.toApplication application
  Gio.applicationHold application'
  Async.async $ runInApplication application' app `finally` runUI
    (Gio.applicationRelease application')

-- | The body of 'runLoop' and of 'runInApplication'. With an
-- application, the window is registered with it and taken down at the
-- end; without one, neither happens.
runLoopIn
  :: (IsBin window, Gtk.IsWindow window)
  => Maybe Gtk.Application
  -> App window state event
  -> IO state
runLoopIn application App {..} = do
  let firstMarkup = view initialState

  events                     <- newChan
  (firstState, subscription) <- do
    firstState <- runUI (create firstMarkup)
    runUI (addWindow application firstState >> presentWindow firstState)
    sub <- subscribe firstMarkup firstState (publishEvent events)
    return (firstState, sub)

  -- What the loop is showing now, so that the window can be taken down
  -- at the end. The loop itself answers with the last model.
  showing <- newIORef firstState

  let core = Async.withAsync (runProducers events inputs) $ \inputs' ->
        Async.withAsync
            (wrappedLoop showing firstState firstMarkup events subscription)
          $ \loop' -> Async.waitEither inputs' loop' >>= \case
              Left _      -> Async.wait loop'
              Right state -> state <$ Async.uninterruptibleCancel inputs'

  case application of
    Nothing -> core
    Just _  -> core
      `finally` (runUI . destroyWindow =<< readIORef showing)

 where
  wrappedLoop showing firstState firstMarkup events subscription =
    loop showing firstState firstMarkup events subscription initialState
      -- Catch exception of linked thread and reraise them without the
      -- async wrapping.
      `catch` (\(Async.ExceptionInLinkedThread _ e) -> throwIO e)

  loop showing oldState oldMarkup events oldSubscription oldModel = do
    event <- readChan events
    case update oldModel event of
      Transition newModel action -> do
        let newMarkup = view newModel

        (newState, sub) <- case patch oldState oldMarkup newMarkup of
          Modify ma -> runUI $ do
            cancel oldSubscription
            newState <- ma
            sub      <- subscribe newMarkup newState (publishEvent events)
            return (newState, sub)
          Replace createNew -> runUI $ do
            destroyWindow oldState
            cancel oldSubscription
            newState <- createNew
            addWindow application newState
            presentWindow newState
            sub <- subscribe newMarkup newState (publishEvent events)
            return (newState, sub)
          Keep -> return (oldState, oldSubscription)

        -- If the action returned by the update function produced an event, then
        -- we write that to the channel.
        -- This is done in a thread to avoid blocking the event loop.
        a <- Async.async $
          -- TODO: Use prioritized queue for events returned by 'update', to take
          -- precendence over those from 'inputs'.
          action >>= maybe (return ()) (writeChan events)

        -- If any exception happen in the action, it will be reraised here and
        -- catched in the thread. See the ExceptionInLinkedThread
        -- catch.
        Async.link a

        writeIORef showing newState
        loop showing newState newMarkup events sub newModel
      Exit -> return oldModel

-- | Tell the application about the window, so that it does not quit
-- while the window is up.
addWindow :: Maybe Gtk.Application -> SomeState -> IO ()
addWindow Nothing     _     = pure ()
addWindow (Just application) state = do
  widget' <- someStateWidget state
  window  <- Gtk.castTo Gtk.Window widget'
  for_ window (Gtk.applicationAddWindow application)

-- | Show the application's top-level window. GTK 4 widgets are visible
-- by default, but a window still has to be presented.
presentWindow :: SomeState -> IO ()
presentWindow state = do
  widget' <- someStateWidget state
  Gtk.castTo Gtk.Window widget' >>= \case
    Just window -> Gtk.windowPresent window
    Nothing     -> Gtk.widgetSetVisible widget' True

-- | Take down the application's top-level window. GTK 4 has no
-- @gtk_widget_destroy@; a window is closed with @gtk_window_destroy@.
destroyWindow :: SomeState -> IO ()
destroyWindow state = do
  widget' <- someStateWidget state
  Gtk.castTo Gtk.Window widget' >>= \case
    Just window -> Gtk.windowDestroy window
    Nothing     -> Gtk.widgetUnparent widget'

-- | Assert that the program was linked using the @-threaded@ flag, to
-- enable the threaded runtime required by this module.
assertRuntimeSupportsBoundThreads :: IO ()
assertRuntimeSupportsBoundThreads = unless rtsSupportsBoundThreads $ do
  hPutStrLn
    stderr
    "GI.Gtk.Declarative.App.Simple requires the program to \
                     \be linked using the threaded runtime of GHC (-threaded \
                     \flag)."
  exitFailure

publishEvent :: Chan event -> event -> IO ()
publishEvent mvar = void . writeChan mvar

runProducers :: Chan event -> [Producer event IO ()] -> IO ()
runProducers chan producers =
  Async.forConcurrently_ producers $ \producer -> do
    runEffect $ producer >-> Pipes.mapM_ (publishEvent chan)
    performGC

runUI :: IO a -> IO a
runUI ma = do
  r <- newEmptyMVar
  runUI_ (ma >>= putMVar r)
  takeMVar r

runUI_ :: IO () -> IO ()
runUI_ ma = do
  tId <- myThreadId

  void . GLib.idleAdd GLib.PRIORITY_DEFAULT $ do
    -- Any exception in the gtk ui thread will be rethrown in the calling thread.
    -- This ensure that this exception won't terminate the application without any control.
    ma `catch` throwTo @SomeException tId
    return False
