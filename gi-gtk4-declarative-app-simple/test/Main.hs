{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedLists  #-}
module Main where

import           Control.Concurrent            (newEmptyMVar, putMVar,
                                                takeMVar, threadDelay)
import qualified Control.Concurrent.Async      as Async
import           Control.Monad                 (void)
import           Data.Foldable                 (traverse_)
import           Data.IORef
import qualified Data.List                     as List
import qualified GI.GLib                       as GLib
import qualified GI.GLib.Constants             as GLib
import qualified GI.Gio                        as Gio
import qualified GI.Gtk                        as Gtk
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.App.Simple
import           Pipes
import           System.Timeout
import           Test.Hspec

main :: IO ()
main = hspec $ do
  describe "run" $ do
    it "processes events from inputs" $
      runApp app { inputs = [yield IncState >> yield Close]} >>= (`shouldBe` Just 1)
    it "finishes app on Exit when input still going" $ do
      runApp app { inputs = [closeLoop] } >>= (`shouldBe` Just 0)
    -- Propagating exception from the view/update/inputs even is
    -- important to crash the application instead of keeping it in a
    -- weird state.
    it "propagates exceptions from view function" $
      runApp app {view = const (error "oh no")} `shouldThrow` errorCall "oh no"
    it "propagates exceptions from update handler itself" $
      runApp app {inputs = [yield ThrowError]} `shouldThrow` errorCall "oh no"
    it "propagates exceptions from the pipeline itself" $
      runApp app {inputs = [error "oh no"]} `shouldThrow` errorCall "oh no"
    describe "propagates exceptions from the Transition" $ do
      it "when the maybe is an exception" $
        runApp app { update = \s _ -> Transition s (perform (pure (error "oh no")))
                   , inputs = [yield ThrowError]
                   } `shouldThrow` errorCall "oh no"
      it "when the io is an exception" $
        runApp app { update = \s _ -> Transition s (perform (error "oh no"))
                   , inputs = [yield ThrowError]
                   } `shouldThrow` errorCall "oh no"
      it "when the newly generated event is an exception" $
        -- Note: forcing the event by pattern matching is important to raise the exception
        runApp app { update = \s ThrowError -> Transition s (perform (pure (Just (error "oh no"))))
                   , inputs = [yield ThrowError]
                   } `shouldThrow` errorCall "oh no"
    -- An application of somebody else's, which is the shape a program
    -- with an application id, actions, and a command line has.
    it "adds its window to an application, and takes it away at the end" $ do
      application <- Gtk.applicationNew (Just "dev.gigtk4declarative.test")
                                        [Gio.ApplicationFlagsNonUnique]
      windowsWhileRunning <- newIORef (0 :: Int)
      _                   <- Gtk.on application #activate $ do
        void $ startInApplication application app { inputs = [closeAfter] }
        -- Once the window is up, count what the application holds.
        _ <- GLib.timeoutAdd GLib.PRIORITY_DEFAULT 400 $ do
          windows <- Gtk.applicationGetWindows application
          writeIORef windowsWhileRunning (length windows)
          pure False
        pure ()
      -- This returns when the application has no windows left, which is
      -- what the end of the loop brings about.
      _        <- Gio.applicationRun application (Just [])
      leftOver <- Gtk.applicationGetWindows application
      counted  <- readIORef windowsWhileRunning
      counted `shouldBe` 1
      length leftOver `shouldBe` 0
    -- A program with something of its own to take down when the window
    -- closes waits on the loop it started.
    it "hands back the loop it started, which answers with the last state" $ do
      application <- Gtk.applicationNew
        (Just "dev.gigtk4declarative.test.waiting")
        [Gio.ApplicationFlagsNonUnique]
      finished <- newEmptyMVar
      _        <- Gtk.on application #activate $ do
        loop <- startInApplication application
                                   app { inputs = [countThenClose] }
        -- In a thread of its own: waiting here would keep the main loop
        -- from starting, and the loop being waited on needs it.
        void . Async.async $ Async.wait loop >>= putMVar finished
      _     <- Gio.applicationRun application (Just [])
      state <- timeout 1000000 (takeMVar finished)
      state `shouldBe` Just 1
    -- A view function can give a window that cannot be patched into
    -- the one on screen, and then the window is built again. The new
    -- one has to be registered with the application in its turn, or
    -- the application is left holding a window that is gone.
    it "registers the window again when a patch replaces it" $ do
      application <- Gtk.applicationNew
        (Just "dev.gigtk4declarative.test.replacing")
        [Gio.ApplicationFlagsNonUnique]
      before <- newIORef []
      after  <- newIORef []
      _      <- Gtk.on application #activate $ do
        void $ startInApplication
          application
          app { view = replacingView, inputs = [replaceThenClose] }
        let record cell delay = void $ GLib.timeoutAdd
              GLib.PRIORITY_DEFAULT
              delay
              (do
                writeIORef cell =<< Gtk.applicationGetWindows application
                pure False
              )
        record before 200
        record after 800
      _        <- Gio.applicationRun application (Just [])
      first    <- readIORef before
      second   <- readIORef after
      leftOver <- Gtk.applicationGetWindows application
      length first `shouldBe` 1
      length second `shouldBe` 1
      -- The window on screen at the end is not the window it started
      -- with, which is what says the replacement happened at all.
      (first == second) `shouldBe` False
      length leftOver `shouldBe` 0
  -- What an update asks the loop to do beside changing the state.
  describe "Cmd" $ do
    it "runs every job of a batch" $ do
      seen <- runJobs
        (\_ -> says "one" <> says "two" <> says "three")
        [yield Begin, stopAfter 400]
      -- The jobs run at the same time as one another, so what comes
      -- back is all of them in no particular order.
      fmap List.sort seen `shouldBe` Just (List.sort ["one", "two", "three"])
    it "takes the events of a stream, in the order they are yielded" $ do
      seen <- runJobs
        (\_ -> stream (traverse_ (yield . Saw) (["one", "two", "three"] :: [String])))
        [yield Begin, stopAfter 400]
      seen `shouldBe` Just ["one", "two", "three"]
    it "does nothing, and holds nothing up, for a command of no jobs" $ do
      seen <- runJobs (\_ -> none) [yield Begin, stopAfter 300]
      seen `shouldBe` Just []
    -- The rule this whole shape exists for: the answer that counts is
    -- the last one asked for.
    it "stops the job that was running under a name, and says nothing"
      $ do
          seen <- runJobs
            (\case
              Begin ->
                keyed "answer" (saysAfter 500 "first")
                  <> keyed "other" (saysAfter 100 "other")
              _ -> keyed "answer" (saysAfter 100 "second")
            )
            [yield Begin >> waiting 200 >> yield Again, stopAfter 900]
          fmap List.sort seen `shouldBe` Just ["other", "second"]
    it "leaves a job with no name alone" $ do
      seen <- runJobs
        (\case
          Begin -> saysAfter 400 "unnamed" <> keyed "answer" (saysAfter 400 "first")
          _     -> keyed "answer" (saysAfter 50 "second")
        )
        [yield Begin >> waiting 100 >> yield Again, stopAfter 900]
      fmap List.sort seen `shouldBe` Just ["second", "unnamed"]
    it "propagates an exception from a job" $
      runJobs (\_ -> perform (error "oh no")) [yield Begin, stopAfter 400]
        `shouldThrow` errorCall "oh no"
    it "propagates an exception from a stream" $
      runJobs (\_ -> stream (error "oh no")) [yield Begin, stopAfter 400]
        `shouldThrow` errorCall "oh no"
  where
    app = App
      { update = update'
      , view = view'
      , inputs = []
      , initialState = 0
      }
    runApp = timeout 1000000 . run
    closeAfter :: Producer AppEvent IO ()
    closeAfter = do
      liftIO (threadDelay 800000)
      yield Close
    -- A patch that replaces the window, and then the end of the loop.
    replaceThenClose :: Producer AppEvent IO ()
    replaceThenClose = do
      liftIO (threadDelay 400000)
      yield IncState
      liftIO (threadDelay 600000)
      yield Close
    countThenClose :: Producer AppEvent IO ()
    countThenClose = do
      liftIO (threadDelay 800000)
      yield IncState
      yield Close
    closeLoop = do
      yield Close
      liftIO (threadDelay 1000000)
      closeLoop
    -- The jobs an update answers with, driven by the inputs given, and
    -- what they sent back.
    runJobs jobs ins =
      fmap (fmap seen) . timeout 3000000 . run $ App
        { view         = \_ -> bin Gtk.Window [] (widget Gtk.Label [])
        , update       = jobsUpdate jobs
        , inputs       = ins
        , initialState = Jobs []
        }
    says text = perform (pure (Just (Saw text)))
    saysAfter delay text =
      perform (threadDelay (delay * 1000) >> pure (Just (Saw text)))
    waiting delay = liftIO (threadDelay (delay * 1000))
    stopAfter delay = waiting delay >> yield Stop

-- | The state of the app that runs jobs: what they sent back.
newtype JobsState = Jobs { seen :: [String] }

data JobsEvent
  = Begin
  | Again
  | Saw String
  | Stop

-- | An update that answers with the jobs under test, and writes down
-- what they send back.
jobsUpdate
  :: (JobsEvent -> Cmd JobsEvent)
  -> JobsState
  -> JobsEvent
  -> Transition JobsState JobsEvent
jobsUpdate jobs state = \case
  Saw text -> Transition state { seen = seen state <> [text] } none
  Stop     -> Exit
  event    -> Transition state (jobs event)

type AppState = Int

data AppEvent = IncState | ThrowError | Close

view' :: AppState -> AppView Gtk.Window AppEvent
view' _ = bin Gtk.Window [] (widget Gtk.Label [])

-- | A view whose two windows cannot be patched into one another: a
-- property the first one sets and the second one does not is what
-- makes the difference.
replacingView :: AppState -> AppView Gtk.Window AppEvent
replacingView 0 = bin Gtk.Window [#title := "first"] (widget Gtk.Label [])
replacingView _ = bin Gtk.Window [] (widget Gtk.Label [])

update' :: AppState -> AppEvent -> Transition AppState AppEvent
update' state = \case
  IncState   -> Transition (state + 1) none
  ThrowError -> error "oh no"
  Close      -> Exit
