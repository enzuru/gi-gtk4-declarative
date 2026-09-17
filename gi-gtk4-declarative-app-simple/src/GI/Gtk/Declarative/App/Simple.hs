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
  , defaultApp
  , AppView
  , Sub
  , sub
  , Transition(..)
  , Cmd
  , none
  , perform
  , emit
  , stream
  , keyed
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
import           Data.Foldable                  ( for_
                                                , traverse_
                                                )
import qualified Data.Function                 as Function
import           Data.IORef
import           Data.List                      ( nubBy )
import           Data.Text                      ( Text )
import           Data.Typeable
import qualified GI.GLib                       as GLib
import qualified GI.Gio                        as Gio
import qualified GI.Gtk                        as Gtk
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.State
import           Pipes                   hiding ( yield )
import qualified Pipes
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
    , subscriptions :: state -> [Sub event]
    -- ^ What the application listens to, which the state decides. The
    -- loop compares these with what it is running after every event:
    -- a name that is new starts, a name that has gone is cancelled,
    -- and a name in both is left running.
    , initialState :: state
    -- ^ The initial state value of the state reduction loop.
    }

-- | An 'App' with nothing in it.
--
-- Fields are added to 'App' as the library grows, and a record built
-- by naming the constructor has to name every field, so building one
-- from this is what survives the next field:
--
-- @
-- run defaultApp { view = view', update = update', initialState = 0 }
-- @
--
-- The three fields with nothing to fall back on answer with an error
-- that names what was left out.
defaultApp :: App window state event
defaultApp = App { update        = missing "update"
                 , view          = missing "view"
                 , inputs        = []
                 , subscriptions = const []
                 , initialState  = missing "initialState"
                 }
 where
  missing :: String -> a
  missing field =
    error
      (  "GI.Gtk.Declarative.App.Simple.defaultApp: this app has no "
      <> field
      )

-- | Something an application listens to for as long as its state asks
-- for it: a file being watched, a clock, a socket.
--
-- The name is the identity. The loop starts a name that is new and
-- cancels one that has gone, and leaves a name it is already running
-- alone, whatever producer is beside it this time. So everything that
-- decides what the producer does belongs in the name:
--
-- @
-- subscriptions = \state ->
--   [ sub ("watch " <> Text.intercalate " " (folders state)) (watching (folders state))
--   | not (null (folders state))
--   ]
-- @
--
-- A producer that ends on its own is not an error and is not started
-- again. Its name stays claimed until the state stops asking for it.
data Sub event = Sub
  { subKey :: Text
  , subRun :: Producer event IO ()
  }

-- | A subscription under this name.
sub :: Text -> Producer event IO () -> Sub event
sub = Sub

-- | The top-level widget for the 'view' function of an 'App',
-- requiring a GTK 'Gtk.Window'.
type AppView window event = Bin window event

-- | The result of applying the 'update' function, deciding if and how to
-- transition to the next state.
data Transition state event =
  -- | Transition to the given state, and run these jobs.
  Transition state (Cmd event)
  -- | Exit the application.
  | Exit

-- | What an update asks the loop to do, beside changing the state.
--
-- A command is a batch of jobs. Each runs in a thread of its own and
-- sends its events back to the loop, and two commands are put together
-- with '<>':
--
-- @
-- update' state = \case
--   Save     -> Transition state { saving = True } (perform (Nothing <$ writeFile' state))
--   Typed t  -> Transition state { typed = t } (keyed "preview" (perform (preview t)))
--   Reset    -> Transition initial (emit [Typed ""] <> perform (Nothing <$ clearFile))
--   Ignore   -> Transition state none
-- @
--
-- A job under a key stops the job that is running under that key, and
-- stopping it that way is silent: no event, no exception, nothing the
-- loop hears about. That is what a preview of a half-written
-- expression wants, and a save that answers a slider being dragged.
newtype Cmd event = Cmd [Job event]

-- | One job of a command: what to run, and the key it runs under, if
-- it has one.
data Job event = Job
  { jobKey :: Maybe Text
  , jobRun :: Producer event IO ()
  }

instance Semigroup (Cmd event) where
  Cmd one <> Cmd other = Cmd (one <> other)

instance Monoid (Cmd event) where
  mempty = Cmd []

-- | A command with nothing to do, which is what an update that only
-- changes the state answers with.
none :: Cmd event
none = mempty

-- | Run an action, and take the event it answers with, if it answers
-- with one. This is what a 'Transition' used to carry on its own.
perform :: IO (Maybe event) -> Cmd event
perform action =
  Cmd [Job Nothing (lift action >>= maybe (pure ()) Pipes.yield)]

-- | Send these events to the loop, in this order, without running
-- anything first.
emit :: [event] -> Cmd event
emit events = Cmd [Job Nothing (traverse_ Pipes.yield events)]

-- | Run a producer, and take every event it yields, for a job that
-- answers more than once: a download reporting its progress, or a
-- process being watched.
stream :: Producer event IO () -> Cmd event
stream producer = Cmd [Job Nothing producer]

-- | Give every job in a command a name. Starting a job under a name
-- stops the job that is running under it, silently, which is how a
-- program keeps the last answer and no other.
--
-- A job with no name is never stopped by another job.
keyed :: Text -> Cmd event -> Cmd event
keyed key (Cmd jobs) = Cmd [ job { jobKey = Just key } | job <- jobs ]

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
  -- The jobs of the commands an update has answered with, by the name
  -- they run under, and the subscriptions the state has asked for.
  jobs                       <- newIORef []
  subs                       <- newIORef []
  (firstState, subscription) <- do
    firstState <- runUI (create firstMarkup)
    runUI (addWindow application firstState >> presentWindow firstState)
    subscribed <- subscribe firstMarkup firstState (publishEvent events)
    return (firstState, subscribed)

  -- What the loop is showing now, so that the window can be taken down
  -- at the end. The loop itself answers with the last model.
  showing <- newIORef firstState

  let core =
        Async.withAsync (runProducers events inputs)
          $ \inputs' ->
              Async.withAsync
                  (wrappedLoop showing
                               firstState
                               firstMarkup
                               events
                               jobs
                               subs
                               subscription
                  )
                $ \loop' -> Async.waitEither inputs' loop' >>= \case
                    Left _      -> Async.wait loop'
                    Right state -> state <$ Async.uninterruptibleCancel inputs'
      -- Whatever ends the loop, what it started ends with it.
      running =
        core `finally` (stopEveryJob jobs >> stopEveryJob subs)

  case application of
    Nothing -> running
    Just _  -> running
      `finally` (runUI . destroyWindow =<< readIORef showing)

 where
  wrappedLoop showing firstState firstMarkup events jobs subs subscription =
    -- What the first state listens to starts before the first event is
    -- read, and inside this thread, so that an exception in it arrives
    -- the way an exception in any other subscription does.
    (   applySubs events subs (subscriptions initialState)
      >> loop showing
              firstState
              firstMarkup
              events
              jobs
              subs
              subscription
              initialState
      )
      -- Catch exception of linked thread and reraise them without the
      -- async wrapping.
      `catch` (\(Async.ExceptionInLinkedThread _ e) -> throwIO e)

  loop showing oldState oldMarkup events jobs subs oldSubscription oldModel = do
    event <- readChan events
    case update oldModel event of
      Transition newModel cmd -> do
        let newMarkup = view newModel

        (newState, sub') <- case patch oldState oldMarkup newMarkup of
          Modify ma -> runUI $ do
            cancel oldSubscription
            newState  <- ma
            subscribed <- subscribe newMarkup newState (publishEvent events)
            return (newState, subscribed)
          Replace createNew -> runUI $ do
            destroyWindow oldState
            cancel oldSubscription
            newState   <- createNew
            addWindow application newState
            presentWindow newState
            subscribed <- subscribe newMarkup newState (publishEvent events)
            return (newState, subscribed)
          Keep -> return (oldState, oldSubscription)

        -- The jobs of the command run in threads of their own, so that
        -- none of them holds up the loop.
        --
        -- TODO: Use prioritized queue for events returned by 'update', to take
        -- precendence over those from 'inputs'.
        runCmd events jobs cmd
        applySubs events subs (subscriptions newModel)

        writeIORef showing newState
        loop showing newState newMarkup events jobs subs sub' newModel
      Exit -> return oldModel

-- | The jobs running under a name. There are as many of these as an
-- application has names for its jobs, which is a handful, so a list of
-- them is cheaper to keep than a map.
type Running = IORef [(Text, Async.Async ())]

-- | Start the jobs of a command.
--
-- A job under a name stops whatever was running under that name. The
-- stopping is a cancellation, and 'Async.link' passes on everything a
-- thread dies of except being cancelled, so the loop hears about an
-- exception in a job and hears nothing about one being replaced.
runCmd :: Chan event -> Running -> Cmd event -> IO ()
runCmd events running (Cmd toRun) = for_ toRun $ \job -> do
  for_ (jobKey job) (stopJob running)
  started <- Async.async
    (runEffect (jobRun job >-> Pipes.mapM_ (publishEvent events)))
  Async.link started
  for_ (jobKey job) $ \key -> modifyIORef' running ((key, started) :)

-- | Stop the job running under this name, if there is one.
stopJob :: Running -> Text -> IO ()
stopJob running key = do
  before <- readIORef running
  writeIORef running (filter ((/= key) . fst) before)
  for_ [ job | (running', job) <- before, running' == key ]
       Async.uninterruptibleCancel

-- | Stop every job, which is what the end of the loop does.
stopEveryJob :: Running -> IO ()
stopEveryJob running = do
  before <- readIORef running
  writeIORef running []
  for_ before (Async.uninterruptibleCancel . snd)

-- | Bring what is running in line with what the state asks for.
--
-- A name in both lists is left alone, producer and all: the producer
-- beside a name this turn may be a different value from the one beside
-- it last turn, and restarting on that would restart a file watcher on
-- every keystroke.
applySubs :: Chan event -> Running -> [Sub event] -> IO ()
applySubs events running wanted = do
  before <- readIORef running
  let asked      = nubBy ((==) `Function.on` subKey) wanted
      wantedKeys = map subKey asked
      kept = [ running' | running' <- before, fst running' `elem` wantedKeys ]
      gone = [ job | (key, job) <- before, key `notElem` wantedKeys ]
      new  = [ s | s <- asked, subKey s `notElem` map fst before ]
  for_ gone Async.uninterruptibleCancel
  started <- traverse start new
  writeIORef running (kept <> started)
 where
  start s = do
    job <- Async.async
      (runEffect (subRun s >-> Pipes.mapM_ (publishEvent events)))
    Async.link job
    pure (subKey s, job)

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
