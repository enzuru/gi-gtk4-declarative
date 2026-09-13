{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedLabels         #-}
{-# LANGUAGE OverloadedLists          #-}
{-# LANGUAGE OverloadedStrings        #-}
module Main where

import           Control.Concurrent
import           Control.Monad
import           Criterion.Main
import           Data.Functor                   ( (<&>) )
import           Data.IORef
import           Data.Text                      ( Text
                                                , pack
                                                )
import           Data.Vector                    ( Vector )
import qualified Data.Vector                   as Vector
import qualified GI.GLib                       as GLib
import qualified GI.GLib.Constants             as GLib

import           GI.Gtk                         ( Box(..)
                                                , Label(..)
                                                , Window(..)
                                                )
import qualified GI.Gtk                        as Gtk
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.EventSource
import           GI.Gtk.Declarative.ModelView.ColumnView
                                                ( ColumnViewParams(..)
                                                , column
                                                , columnView
                                                , defaultColumnViewParams
                                                )
import           GI.Gtk.Declarative.State

testView :: Vector Int -> Widget ()
testView ns = bin Window [] $ container Box [] $ ns <&> \n ->
  BoxChild defaultBoxChildProperties { expand  = True
                                     , fill    = True
                                     , padding = 10
                                     }
    $ widget Label [#label := pack (show n), classes ["a", "b"]]

-- | The same, with an event controller on every child, which is what a
-- widget that answers a click looks like.
clickableView :: Vector Int -> Widget ()
clickableView ns = bin Window [] $ container Box [] $ ns <&> \n ->
  BoxChild defaultBoxChildProperties
    $ widget Label [#label := pack (show n), onClickPressed (\_n _x _y -> ())]

-- | A view without controllers, to measure the other one against.
plainView :: Vector Int -> Widget ()
plainView ns = bin Window [] $ container Box [] $ ns <&> \n ->
  BoxChild defaultBoxChildProperties $ widget Label [#label := pack (show n)]

testPatch
  :: Patchable widget => SomeState -> widget e1 -> widget e2 -> IO SomeState
testPatch state oldView newView = case patch state oldView newView of
  Modify ma -> runUI ma
  _         -> error "Expected a modification."

runUI :: IO a -> IO a
runUI ma = do
  ret <- newEmptyMVar
  void . GLib.idleAdd GLib.PRIORITY_DEFAULT $ do
    ma >>= putMVar ret
    return False
  takeMVar ret

-- | One turn of the loop an application runs: cancel what was
-- subscribed, patch, and subscribe to the new markup.
--
-- The event controllers are looked up when a widget is subscribed to,
-- so a measurement that leaves the subscription out does not see them.
oneTurn
  :: Patchable widget
  => EventSource widget
  => IORef (SomeState, Subscription)
  -> widget ()
  -> widget ()
  -> IO ()
oneTurn cell old new = do
  (state, subscription) <- readIORef cell
  runUI (cancel subscription)
  state'        <- testPatch state old new
  subscription' <- runUI (subscribe new state' (const (pure ())))
  writeIORef cell (state', subscription')

-- | A window showing a column view of this many rows and columns, and
-- the state and markup of the first render.
--
-- The window is large and presented, because a column view builds
-- widgets for the rows on screen and for no others, and a view nobody
-- can see has no rows.
columnViewOf
  :: Int -> Int -> Vector Text -> IO (SomeState, Vector Text -> Widget ())
columnViewOf theRows theColumns items = do
  let cells :: Vector Text -> Widget ()
      cells value = columnView
        []
        (defaultColumnViewParams
            (Vector.fromList
              [ column
                  (pack (show index))
                  (pack (show index))
                  (\text ->
                    widget Label [#label := (text <> "-" <> pack (show index))]
                  )
              | index <- [1 .. theColumns]
              ]
            )
          )
          { rows = value
          }
  state <- runUI $ do
    state'   <- create (cells items)
    view     <- someStateWidget state'
    window   <- Gtk.new
      Gtk.Window
      [#defaultWidth Gtk.:= 1200, #defaultHeight Gtk.:= 900]
    scroller <- Gtk.new Gtk.ScrolledWindow []
    Gtk.scrolledWindowSetChild scroller (Just view)
    Gtk.windowSetChild window (Just scroller)
    Gtk.windowPresent window
    pure state'
  -- Let GTK lay the view out and bind the rows that fit.
  threadDelay 1000000
  _ <- runUI (pure ())
  pure (state, cells)
 where
  _unused = theRows

rowsOf :: Int -> Int -> Vector Text
rowsOf count from =
  Vector.fromList [ pack (show (from + index)) | index <- [1 .. count] ]

main :: IO ()
main = do
  Gtk.init
  mainLoop <- GLib.mainLoopNew Nothing False
  let initialView = testView (Vector.enumFromN 1 100)
  initialState <- create initialView
  window       <- Gtk.unsafeCastTo Gtk.Window =<< someStateWidget initialState
  Gtk.windowPresent window
  _ <- forkOS $ do
    -- Two windows of children that are subscribed to on every turn,
    -- one with an event controller on each child and one without.
    let clickableOne = clickableView (Vector.enumFromN 1 200)
        clickableTwo = clickableView (Vector.enumFromN 2 200)
        plainOne     = plainView (Vector.enumFromN 1 200)
        plainTwo     = plainView (Vector.enumFromN 2 200)
    clickableState <- create clickableOne
    clickableSub   <- subscribe clickableOne clickableState (const (pure ()))
    clickableCell  <- newIORef (clickableState, clickableSub)
    plainState     <- create plainOne
    plainSub       <- subscribe plainOne plainState (const (pure ()))
    plainCell      <- newIORef (plainState, plainSub)

    -- A column view of the size of a spreadsheet on screen.
    let firstRows   = rowsOf 100 0
        oneChanged  = firstRows Vector.// [(0, "changed")]
        allChanged  = rowsOf 100 1000
    (viewState, viewMarkup) <- columnViewOf 100 10 firstRows
    viewCell                <- newIORef viewState

    defaultMain
      [ bgroup
        "patch"
        [ bench "Modify (equal)" . whnfIO . replicateM_ 10 $ do
          s1 <- testPatch initialState initialView initialView
          void $ testPatch s1 initialView initialView
        , bench "Modify (diff)" . whnfIO . replicateM_ 10 $ do
          s1 <- testPatch initialState initialView initialView
          -- The same number of children, with different labels: this
          -- measures a patch of every child, not the cost of adding
          -- one. Patching 100 children into 101 grows the window by
          -- one label per iteration, until X refuses to allocate it.
          void $ testPatch s1 initialView (testView (Vector.enumFromN 2 100))
        ]
      , bgroup
        "subscribe"
        [ bench "200 children, a controller each" . whnfIO $ do
          oneTurn clickableCell clickableOne clickableTwo
          oneTurn clickableCell clickableTwo clickableOne
        , bench "200 children, no controllers" . whnfIO $ do
          oneTurn plainCell plainOne plainTwo
          oneTurn plainCell plainTwo plainOne
        ]
      , bgroup
        "column view"
        [ bench "100 rows, one changed" . whnfIO $ do
          state <- readIORef viewCell
          state' <- testPatch state (viewMarkup firstRows) (viewMarkup oneChanged)
          writeIORef viewCell =<< testPatch state'
                                            (viewMarkup oneChanged)
                                            (viewMarkup firstRows)
        , bench "100 rows, every one changed" . whnfIO $ do
          state <- readIORef viewCell
          state' <- testPatch state (viewMarkup firstRows) (viewMarkup allChanged)
          writeIORef viewCell =<< testPatch state'
                                            (viewMarkup allChanged)
                                            (viewMarkup firstRows)
        ]
      ]
    GLib.mainLoopQuit mainLoop
  GLib.mainLoopRun mainLoop
