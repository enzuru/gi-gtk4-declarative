{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}

module GI.Gtk.Declarative.TestWidget where

import           Control.Applicative
import           Control.Monad.Except
import           Control.Monad.IO.Class             ( MonadIO, liftIO )
import           Data.Int                           ( Int32 )
import           Data.Text                          ( Text )
import           Data.Traversable                   ( for )
import           Data.List                          ( sortOn )
import           Data.Vector                        ( Vector )
import qualified Data.Vector                       as Vector
import           Data.Void
import qualified GI.Gtk                            as Gtk
import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Container.Class ( childWidgets )
import           GI.Gtk.Declarative.Container.Grid as Grid
import           GI.Gtk.Declarative.EventSource
import           Hedgehog                    hiding ( label )
import qualified Hedgehog.Gen                      as Gen
import qualified Hedgehog.Range                    as Range
import           Prelude

-- | GTK widgets cannot (in any practical, generic sense) be compared and shown
-- in tests, so we represent widgets in property tests using this data
-- structure. We convert between this representation, declarative widgets, and
-- instantiated GTK widgets.
data TestWidget
  = TestButton Text (Maybe Bool)
  | TestCustomWidget (Maybe Text)
  | TestScrolledWindow (Maybe Gtk.PolicyType) TestWidget
  | TestBox (Maybe Gtk.Orientation) [TestBoxChild]
  | TestGrid [TestGridChild]
  deriving (Eq, Show)

data TestBoxChild = TestBoxChild BoxChildProperties TestWidget
  deriving (Eq, Show)

data TestGridChild = TestGridChild GridChildProperties TestWidget
  deriving (Eq, Show)

isNested :: TestWidget -> Bool
isNested = \case
  TestButton{}                  -> False
  TestCustomWidget{}            -> False
  TestScrolledWindow _ _        -> True
  TestBox            _ children -> not (null children)
  TestGrid children             -> not (null children)

class HasGtkDefaults a where
  setDefaults :: a -> a

instance HasGtkDefaults TestWidget where
  setDefaults = \case
    TestButton label useUnderline ->
      TestButton label (useUnderline <|> Just False)
    -- An entry with no placeholder text set reads back as none, so
    -- there is no default to fill in here.
    TestCustomWidget placeholder -> TestCustomWidget placeholder
    TestScrolledWindow policy child -> TestScrolledWindow
      (policy <|> Just Gtk.PolicyTypeAutomatic)
      (setDefaults child)
    TestBox orientation children -> TestBox
      (orientation <|> Just Gtk.OrientationHorizontal)
      (map setDefaults children)
    TestGrid children ->
      TestGrid (map setDefaults children)

instance HasGtkDefaults TestBoxChild where
  setDefaults = \case
    TestBoxChild props child -> TestBoxChild props (setDefaults child)

instance HasGtkDefaults TestGridChild where
  setDefaults = \case
    TestGridChild props child -> TestGridChild props (setDefaults child)

onlyJusts :: Vector (Maybe a) -> Vector a
onlyJusts = Vector.concatMap (maybe Vector.empty Vector.singleton)

toTestWidget :: TestWidget -> Widget Void
toTestWidget = \case
  TestCustomWidget placeholder -> Widget (CustomWidget { .. })
   where
    customParams     = ()
    customAttributes = case placeholder of
      Just t  -> [#placeholderText := t]
      Nothing -> []
    customWidget = Gtk.Entry
    customCreate () = do
      entry <- Gtk.new Gtk.Entry []
      return (entry, ())
    customPatch :: () -> () -> () -> CustomPatch Gtk.Entry ()
    customPatch _ () () = CustomKeep
    customSubscribe
      :: () -> () -> Gtk.Entry -> (Void -> IO ()) -> IO Subscription
    customSubscribe () () _entry _cb = do
      return (fromCancellation (pure ()))
  TestButton label useUnderline -> widget
    Gtk.Button
    (onlyJusts [Just (#label := label), (#useUnderline :=) <$> useUnderline])
  TestScrolledWindow policy child -> bin
    Gtk.ScrolledWindow
    (onlyJusts [(#vscrollbarPolicy :=) <$> policy])
    (toTestWidget child)
  TestBox orientation children -> container
    Gtk.Box
    (onlyJusts [(#orientation :=) <$> orientation])
    (Vector.map
      (\(TestBoxChild props child) -> BoxChild props (toTestWidget child))
      (Vector.fromList children)
    )
  TestGrid children -> container
    Gtk.Grid
    []
    (Vector.map
      (\(TestGridChild props child) -> GridChild props (toTestWidget child))
      (Vector.fromList children)
    )

-- | Read a GTK widget back as a 'TestWidget'. GTK 4 has no
-- @gtk_container_get_children@ and no child properties, so the tree is
-- walked through the sibling chain and each container is asked for its
-- own child state.
fromGtkWidget :: (MonadIO m) => Gtk.Widget -> m (Either Text TestWidget)
fromGtkWidget = runExceptT . go
 where
  go :: (MonadIO m) => Gtk.Widget -> ExceptT Text m TestWidget
  go w = do
    casts <- liftIO $ do
      box    <- Gtk.castTo Gtk.Box w
      grid   <- Gtk.castTo Gtk.Grid w
      scroll <- Gtk.castTo Gtk.ScrolledWindow w
      button <- Gtk.castTo Gtk.Button w
      entry  <- Gtk.castTo Gtk.Entry w
      pure (box, grid, scroll, button, entry)
    case casts of
      (Just box, _, _, _, _) -> do
        childGtkWidgets <- childWidgets box
        boxChildProps   <- for childGtkWidgets (boxChildProperties box)
        childWidgets'   <- traverse go childGtkWidgets
        orientation     <- Just <$> Gtk.get box #orientation
        pure
          (TestBox
            orientation
            (Vector.toList
              (Vector.zipWith TestBoxChild boxChildProps childWidgets')
            )
          )
      (_, Just grid, _, _, _) -> do
        childGtkWidgets <- childWidgets grid
        gridChildren    <- for childGtkWidgets $ \childGtkWidget -> do
          (leftAttach, topAttach, width, height) <- Gtk.gridQueryChild
            grid
            childGtkWidget
          child <- go childGtkWidget
          pure (TestGridChild GridChildProperties {..} child)
        -- the order of the children is not maintained by the Grid, so we
        -- need to sort here to allow accurate comparisons of the children
        let sortedChildren =
              sortOn (\(TestGridChild p _) -> topAttach p)
                     (Vector.toList gridChildren)
        pure (TestGrid sortedChildren)
      (_, _, Just win, _, _) -> do
        w' <-
          Gtk.scrolledWindowGetChild win
            >>= maybe (throwError "No child in scrolled window") pure
        vscrollbarPolicy <- Just <$> Gtk.get win #vscrollbarPolicy
        -- A child that does not scroll on its own is wrapped in a
        -- viewport by the scrolled window.
        viewport         <- liftIO (Gtk.castTo Gtk.Viewport w')
        child            <- case viewport of
          Nothing -> pure w'
          Just v ->
            Gtk.viewportGetChild v
              >>= maybe (throwError "No child in viewport") pure
        TestScrolledWindow vscrollbarPolicy <$> go child
      (_, _, _, Just btn, _) ->
        TestButton
          <$> (maybe "" id <$> Gtk.get btn #label)
          <*> (Just <$> Gtk.get btn #useUnderline)
      (_, _, _, _, Just entry) ->
        TestCustomWidget <$> Gtk.get entry #placeholderText
      _ -> do
        name <- Gtk.widgetGetName w
        throwError ("Unsupported TestWidget: " <> name)

-- | Read back the properties a box applied to one of its children.
boxChildProperties
  :: MonadIO m => Gtk.Box -> Gtk.Widget -> m BoxChildProperties
boxChildProperties box child = do
  orientation <- Gtk.orientableGetOrientation box
  case orientation of
    Gtk.OrientationVertical -> do
      expand <- Gtk.widgetGetVexpand child
      align  <- Gtk.widgetGetValign child
      margin <- Gtk.widgetGetMarginTop child
      pure (BoxChildProperties expand (align == Gtk.AlignFill) (fromIntegral margin))
    _ -> do
      expand <- Gtk.widgetGetHexpand child
      align  <- Gtk.widgetGetHalign child
      margin <- Gtk.widgetGetMarginStart child
      pure (BoxChildProperties expand (align == Gtk.AlignFill) (fromIntegral margin))

-- * Generators

genTestWidget :: Gen TestWidget
genTestWidget = Gen.frequency
  (map (3, ) leaves <> pure
    ( 2
    , Gen.recursive
      Gen.choice
      leaves
      (  subwidgets genTestBoxFrom
      <> subwidgets getTestGridFrom
      <> [ Gen.subtermM
             genTestWidget
             (\c -> TestScrolledWindow <$> Gen.maybe genPolicyType <*> pure c)
         ]
      )
    )
  )
 where
  leaves = [genCustomWidget, genButton]
  -- In lack of `subtermN` (https://github.com/hedgehogqa/haskell-hedgehog/issues/119), we use this terrible hack:
  subwidgets :: ([TestWidget] -> Gen TestWidget) -> [Gen TestWidget]
  subwidgets f =
    [ f []
    , Gen.subtermM genTestWidget (\w -> f [w])
    , Gen.subtermM2 genTestWidget genTestWidget (\w1 w2 -> f [w1, w2])
    , Gen.subtermM3 genTestWidget
                    genTestWidget
                    genTestWidget
                    (\w1 w2 w3 -> f [w1, w2, w3])
    ]
  genTestBoxFrom ws = do
    children <- for ws $ \w -> do
      props <- genBoxChildProperties
      pure (TestBoxChild props w)
    o <- Gen.maybe genOrientation
    pure (TestBox o children)
  getTestGridFrom ws = do
    children <- for (zip [0 ..] ws) $ \(i, w) -> do
      props <- genGridChildProperties i
      pure (TestGridChild props w)
    pure (TestGrid children)

genOrientation :: Gen Gtk.Orientation
genOrientation =
  Gen.choice [pure Gtk.OrientationVertical, pure Gtk.OrientationHorizontal]

genPolicyType :: Gen Gtk.PolicyType
genPolicyType = Gen.choice
  (map
    pure
    [ Gtk.PolicyTypeAlways
    , Gtk.PolicyTypeAutomatic
    , Gtk.PolicyTypeExternal
    , Gtk.PolicyTypeNever
    ]
  )

genBoxChildProperties :: Gen BoxChildProperties
genBoxChildProperties =
  BoxChildProperties <$> Gen.bool <*> Gen.bool <*> Gen.word32
    (Range.linear 0 10)

genGridChildProperties :: Int32 -> Gen GridChildProperties
genGridChildProperties rowN = do
  width      <- Gen.int32 (Range.linear 1 10)
  height     <- Gen.int32 (Range.linear 1 5)
  leftAttach <- Gen.int32 (Range.linear 0 10)
  topAttach  <- Gen.int32 (Range.constant (rowN * 5) (rowN * 5 + 5 - height))
  pure GridChildProperties {..}

genCustomWidget :: Gen TestWidget
genCustomWidget = do
  TestCustomWidget <$> Gen.maybe (Gen.choice [pure "Type here"])

genButton :: Gen TestWidget
genButton = do
  TestButton <$> Gen.text (Range.linear 0 10) Gen.unicode <*> Gen.maybe Gen.bool
