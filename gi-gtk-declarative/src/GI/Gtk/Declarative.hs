-- | The declarative layer on top of GTK lets you describe your user
-- interface as a declarative hierarchy of objects, using data
-- structures and pure functions. You can use the declarative event
-- handling to build reusable widgets. The "Patch" typeclass, and the
-- instances provided by this library, performs minimal updates to GTK
-- widgets using the underlying imperative operations, so that your
-- rendering can always be a pure function from your state to a
-- "Widget".
-- Several container modules define children with the same field names
-- (@properties@, @child@), so, as with 'GI.Gtk.Declarative.Container.Grid',
-- they are imported here for their instances alone. Import the module of
-- the container you use to get its child type and properties.
module GI.Gtk.Declarative
  ( module Export
  )
where

import           GI.Gtk.Declarative.Attributes as Export
import           GI.Gtk.Declarative.Bin        as Export
                                                ( Bin
                                                , IsBin
                                                , bin
                                                )
import           GI.Gtk.Declarative.Container  as Export
                                                ( Container
                                                , container
                                                )
import           GI.Gtk.Declarative.Container.ActionBar
                                               as Export
                                                ( )
import           GI.Gtk.Declarative.Container.Box
                                               as Export
import           GI.Gtk.Declarative.Container.CenterBox
                                               as Export
import           GI.Gtk.Declarative.Container.Fixed
                                               as Export
                                                ( )
import           GI.Gtk.Declarative.Container.FlowBox
                                               as Export
                                                ( )
import           GI.Gtk.Declarative.Container.Grid
                                               as Export
                                                ( )
import           GI.Gtk.Declarative.Container.HeaderBar
                                               as Export
                                                ( )
import           GI.Gtk.Declarative.Container.ListBox
                                               as Export
                                                ( )
import           GI.Gtk.Declarative.Container.Overlay
                                               as Export
                                                ( )
import           GI.Gtk.Declarative.Container.Paned
                                               as Export
import           GI.Gtk.Declarative.Container.Notebook
                                               as Export
import           GI.Gtk.Declarative.Container.Stack
                                               as Export
                                                ( )
import           GI.Gtk.Declarative.CustomWidget
                                               as Export
import           GI.Gtk.Declarative.EventController
                                               as Export
import           GI.Gtk.Declarative.MenuModel  as Export
import           GI.Gtk.Declarative.Patch      as Export
import           GI.Gtk.Declarative.SingleWidget
                                               as Export
import           GI.Gtk.Declarative.Slots      as Export
import           GI.Gtk.Declarative.Widget     as Export
import           GI.Gtk.Declarative.Widget.Conversions
                                               as Export
                                                ( )
