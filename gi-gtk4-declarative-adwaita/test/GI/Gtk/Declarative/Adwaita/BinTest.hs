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
import           Data.Vector                    ( Vector )
import qualified GI.Adw                        as Adw
import qualified GI.Gtk                        as Gtk
import           Hedgehog                hiding ( label )

import           GI.Gtk.Declarative
import           GI.Gtk.Declarative.Adwaita.Bin ( )
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

tests :: IO Bool
tests = checkParallel $$(discover)
