{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedLists  #-}
module Main where

import           Control.Concurrent            (newEmptyMVar, putMVar,
                                                takeMVar, threadDelay)
import qualified Control.Concurrent.Async      as Async
import           Control.Monad                 (forever, void)
import           Data.Bifunctor                (bimap)
import           Data.Foldable                 (traverse_)
import           Data.IORef
import qualified Data.List                     as List
import qualified Data.Text                     as Text
import qualified GI.GLib                       as GLib
import qualified GI.GLib.Constants             as GLib
import qualified GI.Gio                        as Gio
import qualified GI.Gtk                        as Gtk
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.App.Simple
import           Pipes
import qualified Pipes.Prelude                 as Pipes
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
  -- A command read as another kind of event, which is how a part of
  -- an application that has its own events goes inside one that has
  -- others.
  describe "mapping" $ do
    it "wraps the events of a command" $ do
      seen <- runJobs (\_ -> Said <$> saysPlain "one")
                      [yield Begin, stopAfter 400]
      seen `shouldBe` Just ["said one"]
    it "wraps the events of a stream, and keeps taking them" $ do
      seen <- runJobs
        (\_ -> Said <$> stream (traverse_ yield (["one", "two", "three"] :: [String])))
        [yield Begin, stopAfter 400]
      seen `shouldBe` Just ["said one", "said two", "said three"]
    it "wraps the state and the events of a transition" $ do
      let stepped = bimap (+ (1 :: Int)) Saw (Transition 1 (emit ["one"]))
      case stepped of
        Transition state cmd -> do
          state `shouldBe` 2
          jobEvents cmd `shouldReturn` [Saw "one"]
        Exit -> expectationFailure "a transition became an exit"
    it "leaves an exit alone" $ do
      let stepped = fmap Saw (Exit :: Transition Int String)
      case stepped of
        Exit          -> pure ()
        Transition{}  -> expectationFailure "an exit became a transition"
  -- A command can be opened up, so that a test can say what it does
  -- without running a loop.
  describe "jobsOf" $ do
    it "gives the jobs of a command, with the names they run under" $ do
      let named = keyed "x" (emit [1 :: Int, 2]) <> perform (pure Nothing)
      map fst (jobsOf named) `shouldBe` [Just "x", Nothing]
    it "gives the events a job yields" $
      jobEvents (keyed "x" (emit [1 :: Int, 2])) `shouldReturn` [1, 2]
  -- Names are shared by everything the loop runs, so a part of an
  -- application that is there twice has to say which one it is.
  describe "qualifying" $ do
    it "puts a prefix in front of a name, and leaves an unnamed job alone"
      $ do
          let mixed = keyed "preview" (emit [1 :: Int]) <> perform (pure Nothing)
          map fst (jobsOf (qualifying "tab-3" mixed))
            `shouldBe` [Just "tab-3/preview", Nothing]
    -- The reason it is there: without it these two stop each other.
    it "keeps two parts from stopping each other's jobs" $ do
      seen <- runJobs
        (\case
          Begin ->
            qualifying "one" (keyed "answer" (saysAfter 300 "from one"))
              <> qualifying "two" (keyed "answer" (saysAfter 300 "from two"))
          _ -> none
        )
        [yield Begin, stopAfter 800]
      fmap List.sort seen `shouldBe` Just ["from one", "from two"]
    it "renames subscriptions the same way" $ do
      let named = qualifyingSubs "tab-3" [sub "ticks" (pure ())]
      map subKey named `shouldBe` ["tab-3/ticks"]
  -- What the application listens to, which its state decides.
  describe "subscriptions" $ do
    -- The rule most easily got wrong: the name is the identity, and
    -- the producer beside it is not.
    it "leaves a name it is already running alone, whatever is beside it"
      $ do
          (starts, heard) <- runSubs
            [ yield (Want ["one"])
            , waiting 200
            , yield (Want ["two"])
            , stopSubsAfter 400
            ]
          starts `shouldBe` 1
          -- Every event came from the producer that started first,
          -- which the second turn did not replace.
          heard `shouldSatisfy` all (== "one")
    it "starts a name once, however many turns it lives through" $ do
      (starts, _) <- runSubs
        (  [yield (Want ["one"])]
        <> concat (replicate 10 [waiting 30, yield (Want ["one"])])
        <> [stopSubsAfter 300]
        )
      starts `shouldBe` 1
    it "starts a name that is new" $ do
      (starts, heard) <- runSubs
        [ yield (Want [])
        , waiting 200
        , yield (Want ["one"])
        , stopSubsAfter 400
        ]
      starts `shouldBe` 1
      heard `shouldSatisfy` not . null
    it "cancels a name that has gone, and hears nothing more from it" $ do
      ticks <- newIORef (0 :: Int)
      let counted = do
            liftIO (modifyIORef' ticks (+ 1))
            liftIO (threadDelay 50000)
            counted
      atDrop <- newIORef (0 :: Int)
      _      <- timeout 3000000 . run $ defaultApp
        { view          = \_ -> bin Gtk.Window [] (widget Gtk.Label [])
        , update        = subsUpdate
        , subscriptions = \state ->
                            [ sub "one" counted | "one" `elem` wanted state ]
        , inputs        = [ yield (Want ["one"])
                          , waiting 300
                            >> yield (Want [])
                            >> waiting 100
                            >> liftIO (writeIORef atDrop =<< readIORef ticks)
                            >> waiting 400
                            >> yield StopSubs
                          ]
        , initialState  = Subs [] []
        }
      dropped <- readIORef atDrop
      ended   <- readIORef ticks
      -- It was running, and it stopped when its name went.
      dropped `shouldSatisfy` (> 0)
      ended `shouldBe` dropped
    it "cancels everything it is running when the app exits" $ do
      ticks <- newIORef (0 :: Int)
      let counted = do
            liftIO (modifyIORef' ticks (+ 1))
            liftIO (threadDelay 50000)
            counted
      _ <- timeout 3000000 . run $ defaultApp
        { view          = \_ -> bin Gtk.Window [] (widget Gtk.Label [])
        , update        = subsUpdate
        , subscriptions = \_ -> [sub "one" counted, sub "two" counted]
        , inputs        = [stopSubsAfter 300]
        , initialState  = Subs ["one", "two"] []
        }
      atExit <- readIORef ticks
      threadDelay 400000
      afterwards <- readIORef ticks
      atExit `shouldSatisfy` (> 0)
      afterwards `shouldBe` atExit
  where
    app = defaultApp
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
      fmap (fmap seen) . timeout 3000000 . run $ defaultApp
        { view         = \_ -> bin Gtk.Window [] (widget Gtk.Label [])
        , update       = jobsUpdate jobs
        , inputs       = ins
        , initialState = Jobs []
        }
    says text = perform (pure (Just (Saw text)))
    -- The same, answering with the text itself, for a command that is
    -- mapped into an event by whoever takes it.
    saysPlain text = perform (pure (Just text))
    -- The events a job yields, for a job that ends.
    jobEvents cmd = case jobsOf cmd of
      [(_, producer)] -> Pipes.toListM producer
      jobs            -> fail ("expected one job, found " <> show (length jobs))
    -- An app whose state says what to listen to. Each subscription
    -- counts itself as it starts, and then says its own name over and
    -- over, so that a producer that was replaced can be told from one
    -- that was left alone.
    runSubs ins = do
      starts <- newIORef (0 :: Int)
      final  <- timeout 3000000 . run $ defaultApp
        { view          = \_ -> bin Gtk.Window [] (widget Gtk.Label [])
        , update        = subsUpdate
        , subscriptions = \state ->
          [ sub "the name" (saying starts (Text.unpack name))
          | name <- wanted state
          ]
        , inputs        = ins
        , initialState  = Subs [] []
        }
      started <- readIORef starts
      pure (started, maybe [] listened final)
    saying starts name = do
      liftIO (modifyIORef' starts (+ 1))
      forever $ do
        yield (Listened name)
        liftIO (threadDelay 50000)
    saysAfter delay text =
      perform (threadDelay (delay * 1000) >> pure (Just (Saw text)))
    waiting delay = liftIO (threadDelay (delay * 1000))
    stopAfter delay = waiting delay >> yield Stop
    stopSubsAfter delay = waiting delay >> yield StopSubs

-- | The state of the app that listens: what it asks to listen to, and
-- what it heard.
data SubsState = Subs
  { wanted   :: [Text.Text]
  , listened :: [String]
  }

data SubsEvent
  = Want [Text.Text]
  | Listened String
  | StopSubs

subsUpdate :: SubsState -> SubsEvent -> Transition SubsState SubsEvent
subsUpdate state = \case
  Want names  -> Transition state { wanted = names } none
  Listened it -> Transition state { listened = listened state <> [it] } none
  StopSubs    -> Exit

-- | The state of the app that runs jobs: what they sent back.
newtype JobsState = Jobs { seen :: [String] }

data JobsEvent
  = Begin
  | Again
  | Saw String
  -- | What a mapped command answers with, so that a wrapped event can
  -- be told from one that went straight through.
  | Said String
  | Stop
  deriving (Eq, Show)

-- | An update that answers with the jobs under test, and writes down
-- what they send back.
jobsUpdate
  :: (JobsEvent -> Cmd JobsEvent)
  -> JobsState
  -> JobsEvent
  -> Transition JobsState JobsEvent
jobsUpdate jobs state = \case
  Saw text  -> Transition state { seen = seen state <> [text] } none
  Said text -> Transition state { seen = seen state <> ["said " <> text] } none
  Stop      -> Exit
  event     -> Transition state (jobs event)

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
