{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

-- | Tests for the libadwaita widgets that hold one child, and for the
-- bars of a toolbar view.
module GI.Gtk.Declarative.Adwaita.BinTest where

import           Data.Text                      ( Text )
import           Data.Typeable                  ( Typeable )
import           Data.Vector                    ( Vector )
import qualified GI.Adw                        as Adw
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Adwaita.Bin ( )
import           GI.Gtk.Declarative.Bin         ( IsBin(..) )
import           GI.Gtk.Declarative.Adwaita.Slots
import           GI.Gtk.Declarative.Adwaita.TestUtils
import           GI.Gtk.Declarative.State

label :: Text -> Widget event
label text = widget Gtk.Label [#label := text]

-- | Render the first markup, patch it with the others in turn, and
-- hand the widget to the action.
render :: [Widget ()] -> (Gtk.Widget -> IO a) -> IO a
render []             _ = fail "render: no markup to render"
render (first : rest) f = do
  state  <- runUI (create first)
  state' <- step (state, first) rest
  view   <- runUI (someStateWidget state')
  result <- runUI (f view)
  runUI (destroy view)
  pure result
 where
  step (state, _  ) []           = pure state
  step (state, old) (new : more) = do
    patched <- runUI (patch' state old new)
    step (patched, new) more
  -- A window goes away with gtk_window_destroy; anything else is
  -- collected once nothing holds it.
  destroy view = do
    window <- Gtk.castTo Gtk.Window view
    mapM_ Gtk.windowDestroy window

-- * Every widget with an instance
--
-- An instance is two lines naming a setter and a getter for one
-- widget, and two lines are where a wrong name hides: the content of
-- an AdwApplicationWindow is the mistake this package exists to stop
-- somebody making. So every widget with an instance is given a child
-- and asked for it again, through the instance itself.

-- | One widget that holds a child: what to call it, and what it
-- answers with when it is asked for its child.
data BinCase = BinCase
  { caseName :: Text
  , caseRun  :: IO (Maybe Text)
  }

binCase
  :: (Typeable widget, IsBin widget, Gtk.IsWidget widget)
  => Text
  -> (Gtk.ManagedPtr widget -> widget)
  -> BinCase
binCase name ctor = BinCase name $ do
  (parent, found) <- runUI $ do
    let markup = bin ctor [] (label inside) :: Widget ()
    state <- create markup
    built <- someStateWidget state
    typed <- Gtk.unsafeCastTo ctor built
    (,) built <$> getBinChild typed
  answer <- runUI (traverse labelOf found)
  runUI (takeDown parent)
  pure answer

takeDown :: Gtk.Widget -> IO ()
takeDown widget' = do
  window <- Gtk.castTo Gtk.Window widget'
  mapM_ Gtk.windowDestroy window

inside :: Text
inside = "inside"

cases :: [BinCase]
cases =
  [ binCase "ApplicationWindow" Adw.ApplicationWindow
  , binCase "Window"            Adw.Window
  , binCase "ToastOverlay"      Adw.ToastOverlay
  , binCase "Bin"               Adw.Bin
  , binCase "StatusPage"        Adw.StatusPage
  , binCase "Clamp"             Adw.Clamp
  , binCase "Dialog"            Adw.Dialog
  , binCase "ToolbarView"       Adw.ToolbarView
  , binCase "TabOverview"       Adw.TabOverview
  , binCase "NavigationPage"    Adw.NavigationPage
  ]

prop_every_bin_holds_the_child_it_was_given = withTests 1 . property $ do
  answers <- evalIO (traverse run cases)
  answers === map (\theCase -> (caseName theCase, Just inside)) cases
  where run theCase = (,) (caseName theCase) <$> caseRun theCase

-- * The single-child widgets

-- | An @AdwApplicationWindow@ holds its child in the content property.
-- Reading it back through @adw_application_window_get_content@ is what
-- says the right setter was called: the window's own child property
-- holds the layout libadwaita put there, and never the child given
-- here.
prop_an_application_window_holds_its_child_as_content =
  withTests 1 . property $ do
    (content, labels) <- evalIO $ render
      [bin Adw.ApplicationWindow [] (label "the content")]
      (\view -> do
        window   <- Gtk.unsafeCastTo Adw.ApplicationWindow view
        content' <- Adw.applicationWindowGetContent window
        labels'  <- traverse labelOf content'
        below    <- descendantLabels window
        pure (labels', below)
      )
    content === Just "the content"
    labels === ["the content"]

prop_an_adwaita_window_holds_its_child_as_content = withTests 1 . property $ do
  content <- evalIO $ render
    [bin Adw.Window [] (label "the content")]
    (\view -> do
      window <- Gtk.unsafeCastTo Adw.Window view
      traverse labelOf =<< Adw.windowGetContent window
    )
  content === Just "the content"

prop_the_child_of_a_bin_is_patched = withTests 1 . property $ do
  labels <- evalIO $ render
    [bin Adw.Bin [] (label "one"), bin Adw.Bin [] (label "two")]
    descendantLabels
  labels === ["two"]

prop_every_single_child_widget_takes_a_child = withTests 1 . property $ do
  labels <- evalIO $ do
    toast    <- render [bin Adw.ToastOverlay [] (label "toast")]
                       descendantLabels
    status   <- render [bin Adw.StatusPage [] (label "status")]
                       descendantLabels
    clamp    <- render [bin Adw.Clamp [] (label "clamp")] descendantLabels
    toolbar' <- render [bin Adw.ToolbarView [] (label "toolbar")]
                       descendantLabels
    pure ([toast, status, clamp, toolbar'] :: [[Text]])
  labels === [["toast"], ["status"], ["clamp"], ["toolbar"]]

-- | A dialog takes a child as well, and gives it back through its own
-- getter. The child is not below the dialog in the widget tree until
-- the dialog is presented, which is libadwaita's business rather than
-- this library's.
prop_a_dialog_takes_a_child = withTests 1 . property $ do
  inside <- evalIO $ render
    [bin Adw.Dialog [] (label "in the dialog")]
    (\view -> do
      dialog <- Gtk.unsafeCastTo Adw.Dialog view
      traverse labelOf =<< Adw.dialogGetChild dialog
    )
  inside === Just "in the dialog"

-- * The bars of a toolbar view

toolbar :: Vector (Attribute Adw.ToolbarView ()) -> Text -> Widget ()
toolbar bars content = bin Adw.ToolbarView bars (label content)

prop_a_toolbar_view_shows_its_bars = withTests 1 . property $ do
  labels <- evalIO $ render
    [ toolbar [toolbarTopBar (label "top"), toolbarBottomBar (label "bottom")]
              "content"
    ]
    descendantLabels
  labels === ["content", "top", "bottom"]

-- | The widget in a bar is patched where it stands, like the widget in
-- any other slot.
prop_a_bar_is_patched = withTests 1 . property $ do
  labels <- evalIO $ render
    [ toolbar [toolbarTopBar (label "top")]         "content"
    , toolbar [toolbarTopBar (label "another top")] "content"
    ]
    descendantLabels
  labels === ["content", "another top"]

-- | A bar the markup no longer names is taken off the view. The
-- toolbar view has no getter for its bars, so this is what says the
-- library found the old one again.
prop_a_bar_goes_away_with_its_slot = withTests 1 . property $ do
  labels <- evalIO $ render
    [ toolbar [toolbarTopBar (label "top"), toolbarBottomBar (label "bottom")]
              "content"
    , toolbar [toolbarBottomBar (label "bottom")] "content"
    ]
    descendantLabels
  labels === ["content", "bottom"]

-- | A bar that is replaced rather than patched leaves nothing behind.
-- A button reads as the label GTK puts inside it.
prop_a_replaced_bar_leaves_nothing_behind = withTests 1 . property $ do
  labels <- evalIO $ render
    [ toolbar [toolbarTopBar (label "top")] "content"
    , toolbar
      [toolbarTopBar (widget Gtk.Button [#label := ("a button" :: Text)])]
      "content"
    ]
    descendantLabels
  labels === ["content", "a button"]

-- * The two pages of a split view

-- | A navigation split view holds its sidebar and its content in
-- properties rather than as children, and each has to be a page.
prop_a_split_view_holds_its_two_pages = withTests 1 . property $ do
  (sidebar, content) <- evalIO $ render
    [ widget
        Adw.NavigationSplitView
        [ splitViewSidebar (bin Adw.NavigationPage
                                [#title := ("Tools" :: Text)]
                                (label "the list"))
        , splitViewContent (bin Adw.NavigationPage
                                [#title := ("GHC" :: Text)]
                                (label "the pane"))
        ]
    ]
    (\view -> do
      split    <- Gtk.unsafeCastTo Adw.NavigationSplitView view
      sidebar' <- Adw.navigationSplitViewGetSidebar split
      content' <- Adw.navigationSplitViewGetContent split
      (,)
        <$> traverse Adw.navigationPageGetTitle sidebar'
        <*> traverse Adw.navigationPageGetTitle content'
    )
  sidebar === Just "Tools"
  content === Just "GHC"

-- | The page in a slot is patched where it stands, like any other
-- widget in a slot.
prop_a_split_view_page_is_patched = withTests 1 . property $ do
  title <- evalIO $ render
    [ widget Adw.NavigationSplitView [splitViewSidebar (page "Tools")]
    , widget Adw.NavigationSplitView [splitViewSidebar (page "Toolchains")]
    ]
    (\view -> do
      split <- Gtk.unsafeCastTo Adw.NavigationSplitView view
      traverse Adw.navigationPageGetTitle
        =<< Adw.navigationSplitViewGetSidebar split
    )
  title === Just "Toolchains"
 where
  page :: Text -> Widget ()
  page t = bin Adw.NavigationPage [#title := t] (label "body")

-- | An overlay split view is the same shape and takes plain widgets.
prop_an_overlay_split_view_holds_its_two_sides = withTests 1 . property $ do
  (sidebar, content) <- evalIO $ render
    [ widget
        Adw.OverlaySplitView
        [overlaySidebar (label "beside"), overlayContent (label "the rest")]
    ]
    (\view -> do
      split    <- Gtk.unsafeCastTo Adw.OverlaySplitView view
      sidebar' <- Adw.overlaySplitViewGetSidebar split
      content' <- Adw.overlaySplitViewGetContent split
      (,) <$> traverse labelOf sidebar' <*> traverse labelOf content'
    )
  sidebar === Just "beside"
  content === Just "the rest"

-- * The dialog a widget is showing

dialogSaying :: Text -> Widget ()
dialogSaying text = bin Adw.Dialog [#title := text] (label text)

-- | A dialog is neither a child nor a property, so a view says which
-- one is open through a slot. Presenting it is what the slot does.
prop_a_window_presents_the_dialog_in_its_slot = withTests 1 . property $ do
  titles <- evalIO $ render
    [ bin Adw.ApplicationWindow
          [presentedDialog (dialogSaying "Preferences")]
          (label "the window")
    ]
    dialogTitles
  titles === ["Preferences"]

-- | The dialog is patched while it is open, so what it shows follows
-- the state.
prop_a_presented_dialog_is_patched_where_it_stands =
  withTests 1 . property $ do
    titles <- evalIO $ render
      [ bin Adw.ApplicationWindow
            [presentedDialog (dialogSaying "Preferences")]
            (label "the window")
      , bin Adw.ApplicationWindow
            [presentedDialog (dialogSaying "Options")]
            (label "the window")
      ]
      dialogTitles
    titles === ["Options"]

-- | A view that stops naming a dialog closes it.
prop_a_dialog_closes_when_the_slot_is_emptied = withTests 1 . property $ do
  titles <- evalIO $ render
    [ bin Adw.ApplicationWindow
          [presentedDialog (dialogSaying "Preferences")]
          (label "the window")
    , bin Adw.ApplicationWindow [] (label "the window")
    ]
    dialogTitles
  titles === []

-- | The case a program reaches every time somebody presses Escape: the
-- dialog is gone before the view says so. Closing it again is a
-- warning from libadwaita, which this suite now treats as a failure.
prop_a_dialog_the_user_closed_is_let_alone = withTests 1 . property $ do
  titles <- evalIO $ do
    let opened =
          bin Adw.ApplicationWindow
              [presentedDialog (dialogSaying "Preferences")]
              (label "the window") :: Widget ()
        closed = bin Adw.ApplicationWindow [] (label "the window")
    state   <- runUI (create opened)
    window  <- runUI (someStateWidget state)
    -- What Escape does.
    runUI $ do
      dialogs <- dialogsBelow window
      mapM_ Adw.dialogForceClose dialogs
    _ <- runUI (patch' state opened closed)
    runUI (dialogTitles window)
  titles === []

-- | The titles of the dialogs a widget is showing.
dialogTitles :: Gtk.Widget -> IO [Text]
dialogTitles root = traverse Adw.dialogGetTitle =<< dialogsBelow root

dialogsBelow :: Gtk.Widget -> IO [Adw.Dialog]
dialogsBelow root = do
  widgets <- descendants root
  found   <- traverse (Gtk.castTo Adw.Dialog) widgets
  pure (foldr (\x xs -> maybe xs (: xs) x) [] found)

tests :: IO Bool
tests = checkParallel $$(discover)
