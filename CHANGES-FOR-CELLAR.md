# Changes this library needs, for Cellar

Cellar is moving its window onto this library. The plan is in
`MIGRATION.md` in the Cellar repository, and the model views that landed
in `MODEL-VIEWS.md` cover the spreadsheet grid. What follows is
everything else Cellar needs, plus two defects found while reading the
new code.

Seven items. Items 1 and 2 are defects and stand on their own. Items 3
to 7 are features, and Cellar cannot move without any of them.

## Ground rules

- `nix develop --offline -c make check` passes today, exit code 0,
  including the 11 new model-view properties. Keep it passing. It is the
  gate for every item here.
- `nix develop --offline -c make build` is the fast gate while you work.
  Read item 2 first, because that gate has a hole in it right now.
- Add no dependency to the `gi-gtk4-declarative` package. Anything that
  needs libadwaita goes in the new package in item 7.
- Each item names its tests. Write them in the style of the suite that
  is already there, which drives the real widgets under Xvfb and reads
  them back.
- The documentation site lives in `docs/src`. Add a page when an item
  adds a module, and a paragraph when an item changes an API.

## 1. A replaced row is dropped and never comes back

A defect, in
`gi-gtk4-declarative/src/GI/Gtk/Declarative/ModelView/Internal.hs`, in
`rebindRows`.

When `patch` returns `Replace`, the code keeps the old state, because
the cell is not on hand to put a new widget in. Then it writes the
record back with the *new* markup against that old state. The row now
claims to show markup that it does not show. The next bind patches the
new markup against itself, gets `Keep`, and the old widget stays there
for good. Nothing recovers it, because the model did not change and GTK
has no reason to build the row again.

What to do. Put the cell in the row record and do the replace properly:

- Add `rowCell :: Cell` to `Row`.
- Fill it in `showRow`, which already takes the `Cell`.
- In `rebindRows`, handle `Replace` by creating the new state and
  calling `cellSetChild (rowCell row) . Just =<< someStateWidget`, the
  same way `showRow` does.
- Delete the comment that says the cell is not on hand here.

A `Cell` is two closures over a list item that GTK owns, and the record
is deleted on teardown, so holding one for as long as the record lives
is safe.

Test. Add a property to `ModelViewTest` in which a row's markup changes
to a different widget type, with the number of rows left alone. Render,
patch, and then read the realized child back and assert its type. The
test fails before the fix.

## 2. The fast gate does not see the model views

A defect, in `Makefile`, in the `build` target.

The target compiles `GI/Gtk/Declarative.hs` and
`GI/Gtk/Declarative/App/Simple.hs`, and GHC follows the imports from
there. The umbrella module does not re-export the model views, so
`make build` never typechecks `ModelView/Internal.hs`,
`ModelView/ListView.hs`, or `ModelView/ColumnView.hs`. Only `make
check`, which builds the test binary, reaches them.

What to do. Name both public model-view modules on the `ghc` command
line in the `build` target, beside the two that are there now.

Do not put them in the umbrella module. `ListViewParams` and
`ColumnViewParams` share the field names `rows`, `selected`,
`scrollTo`, `onSelected`, and `onActivated`, and re-exporting both makes
those names ambiguous for everybody who imports `GI.Gtk.Declarative`.
Add a line to the umbrella's haddock that says the model views come from
their own modules, and why.

## 3. `afterCreated`

Upstream had this attribute and the fork dropped it. Cellar needs it in
three places: to add its stylesheet provider to the display, to grab
focus on the grid, and to install the drag gesture on the column
headers, which GTK gives no declarative way to reach.

What to do, in `Attributes.hs`:

- Add a constructor to the `Attribute` GADT:
  `AfterCreated :: (widget -> IO ()) -> Attribute widget event`.
- Add `afterCreated :: (widget -> IO ()) -> Attribute widget event`,
  and export it.
- Add the case to `instance Functor (Attribute widget)`. The action
  carries no event, so it passes through.
- Make sure that `collectAttributes` ignores it. It collects properties
  and classes, and this is neither.

Then run the actions after the widget is built, in each `create`:
`SingleWidget.hs`, `Bin.hs`, `Container.hs`, `CustomWidget.hs`,
`ModelView/ListView.hs`, and `ModelView/ColumnView.hs`. Run them once,
at creation, and never on a patch. That is the contract, and the name
says it.

Test. One property per shape, in `PatchTest` or beside it: create a
widget with an `afterCreated` that writes to an `IORef`, assert it ran
once, patch the widget, and assert it did not run again.

## 4. A header menu on a column

Cellar has a menu on the row and column headers: insert, delete, move.
Today it builds a `GtkPopoverMenu` by hand and parents it onto the
header label. GTK 4.22 has
`gtk_column_view_column_set_header_menu`, so the column case belongs in
the library.

What to do, in `ModelView/ColumnView.hs`:

- Add `columnHeaderMenu :: Vector (MenuItem event)` to `Column`, empty
  in `column`. Take the declarative menu items from
  `GI.Gtk.Declarative.MenuModel`, not a `Gio.MenuModel`, so that the
  actions behind the items are wired to the view's sink like every other
  event in the library.
- `MenuModel.buildMenu` takes a widget, because it calls
  `gtk_widget_insert_action_group` on it. A `GtkColumnViewColumn` is not
  a widget. Split `buildMenu` so that the part which builds the model
  and the action group takes no widget, and export it from `MenuModel`
  as internal API. The column view then inserts the group into the
  column *view* widget, under a prefix of its own per column, and calls
  `columnViewColumnSetHeaderMenu` with the model.
- Patch it the way `MenuModel` already patches a menu: rebuild only when
  the shape changes, and write the new dispatch into the `IORef` every
  time, so that a menu whose shape is unchanged still emits this
  render's events.

Test. Add a property that gives a column a header menu, activates the
action behind one item, and asserts the event. `MenuModelTest` shows how
to activate an action from code.

## 5. A list box takes any widget

`IsContainer Gtk.ListBox (Bin Gtk.ListBoxRow)` allows only
`GtkListBoxRow` children. Cellar's list of recent workbooks is made of
`AdwActionRow`, which is a row but not that type, and the functional
dependency on `IsContainer` allows one child type per container, so a
second instance is not an option.

What to do, in `Container/ListBox.hs`. Change the child type to
`Widget`, for both `IsContainer` and `ToChildren`. GTK wraps a child
that is not a row in a row of its own, so the widget still behaves.
Existing code that writes `bin Gtk.ListBoxRow [] child` keeps working,
because a `Bin` converts to a `Widget`.

Confirm the removal path before you call this done. `gtk_list_box_remove`
has to find the row that holds a wrapped child. The GTK documentation
does not say that it does. Add a `ContainerTest` case that puts three
plain labels in a list box, patches to two, and asserts what is left and
that no warning was printed. If GTK does not handle it, wrap the child
in a row inside `appendChild` and keep the wrapper in the instance, and
say so in the haddock.

## 6. `runInApplication`

`run` calls `Gtk.init` and owns the loop. Cellar cannot use it, because
Cellar needs an `AdwApplication`, which calls `adw_init` itself and
carries the application ID, the actions, the accelerators, and the file
named on the command line. `runLoop` runs in a loop somebody else
started, but it never registers its window with the application, and an
application with no window exits as soon as `activate` returns.

What to do, in
`gi-gtk4-declarative-app-simple/src/GI/Gtk/Declarative/App/Simple.hs`:

```haskell
runInApplication
  :: (IsBin window, Gtk.IsWindow window, Gtk.IsApplication app)
  => app
  -> App window state event
  -> IO state
```

It does what `runLoop` does, and three things more. It calls
`gtk_application_add_window` on the window it created, before presenting
it. It does the same again when a patch replaces the window, after the
old one is taken down. When the loop ends, it destroys the window, so
that an application holding no other window quits on its own.

It does not call `Gtk.init`, and it does not make a main loop.

Document the calling shape, because it is the part a reader gets wrong:
the function loops until the application exits, so a caller starts it
with `Async.async` from the `activate` handler and does not wait on it
there. Give that as a code example in the haddock and on the
`docs/src/app-simple.md` page.

Test. Add a case to the app-simple suite that makes a
`Gtk.Application` with `ApplicationFlagsNonUnique`, runs an app in it
from `activate`, and asserts that `gtk_application_get_windows` returns
the one window, and that it is empty again after an `Exit`.

## 7. A libadwaita package

A third package, `gi-gtk4-declarative-adwaita`, laid out like
`gi-gtk4-declarative-app-simple`: its own cabal file, its own
`src`, its own test suite, and a line in `cabal.project`, `hie.yaml`,
`flake.nix`, and the `Makefile`. It depends on `gi-adwaita` and on the
core package. The core keeps no knowledge of it.

### 7a. The single-child widgets

`GI.Gtk.Declarative.Adwaita.Bin`, holding `IsBin` instances. Cellar uses
all of these:

- `Adw.ApplicationWindow`, whose child is the content, set with
  `adw_application_window_set_content`. Note that this is not
  `gtk_window_set_child`, and that using the wrong one is a warning at
  run time rather than an error.
- `Adw.Window`, the same way.
- `Adw.ToastOverlay`, `Adw.Bin`, `Adw.StatusPage`, `Adw.Clamp`, and
  `Adw.Dialog`, each with its own `set_child` and `get_child`.

`Adw.ToolbarView` holds a content child and any number of top and bottom
bars. Give it `IsBin` for the content, and two slots in
`GI.Gtk.Declarative.Adwaita.Slots` for a single top bar and a single
bottom bar, in the style of `GI.Gtk.Declarative.Slots`. A view with more
than one bar per end is out of scope until something needs it.

### 7b. A declarative tab view

`GI.Gtk.Declarative.Adwaita.TabView`. `AdwTabView` holds pages, and a
page holds a child widget and a title. Cellar's sheets are its tabs, so
this decides how the Cellar window is shaped.

Model it on the column view, which solved the same problem: match by a
key the caller supplies.

```haskell
data Tab event = Tab
  { tabKey   :: Text          -- matches one render with the next
  , tabTitle :: Text
  , tabChild :: Widget event
  }

data TabViewParams event = TabViewParams
  { tabs         :: Vector (Tab event)
  , selected     :: Maybe Text
  , onSelected   :: Maybe (Text -> event)
  , onReordered  :: Maybe (Vector Text -> event)
  , onClosePage  :: Maybe (Text -> event)
  , closeAnswer  :: Maybe (Text, Bool)
  }
```

A tab that keeps its key keeps its page and its child state, which is
patched like any other subtree. A new key is appended with
`adw_tab_view_append`. A key that is gone is closed with
`adw_tab_view_close_page`, followed at once by
`adw_tab_view_close_page_finish` with `True`, so that the program's own
removal does not go through the confirmation path. Order follows the
vector, with `adw_tab_view_reorder_page`.

The closing protocol is the part that needs care, and it is why
`closeAnswer` is there. When somebody clicks the close button on a tab,
`AdwTabView` emits `close-page`. A handler that returns `True` stops the
default, and the program is then expected to call
`adw_tab_view_close_page_finish` once it knows the answer. So: emit
`onClosePage` with the key, return `True`, and remember the page.
`closeAnswer` carries the answer back in the next render, and the patch
calls `close_page_finish` with it. Cellar asks the user in a dialog
between those two points, which is exactly the case this shape exists
for.

`onReordered` reports the user dragging a tab, which Cellar writes to
disk as the sheet order.

Test. Four properties: a tab that keeps its key keeps its widget, a new
key is appended in the right place, a dropped key closes without asking,
and a close from the tab's own button emits `onClosePage` and closes
only after `closeAnswer` says so.

### 7c. The rows

Nothing to add. `Adw.ActionRow` and `Adw.PreferencesRow` are leaves with
properties, so `widget Adw.ActionRow [#title := ...]` works once item 5
lets a list box take a widget that is not a `GtkListBoxRow`.

## What Cellar still does by hand afterwards

Say this in the documentation of the column view, because a reader who
expects otherwise finds out the hard way.

GTK has no factory for column headers. A program that wants a gesture or
a widget of its own on a header reaches the built-in header widget by
hand, which is what item 3 is for. This is a GTK limitation and not one
of this library.
