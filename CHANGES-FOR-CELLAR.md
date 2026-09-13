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

## Two more, found while porting Cellar's grid

Cellar's grid now draws through `ModelView.ColumnView`, and both of these
turned up in the working program rather than in a test. Item 9 is not
about Cellar.

### 8. A view that selects nothing

`newViewState` always builds a `Gtk.SingleSelection`, so GTK highlights a
whole row as soon as a cell in it is clicked. A spreadsheet has no
selected row. What is selected is a cell, and Cellar draws that itself.
The highlight is turned off in Cellar's stylesheet at the moment, which
fights GTK rather than asking it for what is wanted.

What to do. Add a selection mode to the parameters of both views, along
these lines:

```haskell
data SelectionMode = SelectNothing | SelectOne
```

`SelectOne` keeps today's behavior and stays the default.
`SelectNothing` builds a `Gtk.NoSelection` instead. `viewSelection` then
holds a `Gtk.SelectionModel` rather than a `Gtk.SingleSelection`, and
`selected`, `onSelected`, and the selection command do nothing under
`SelectNothing`, which the haddock has to say.

Test. A property that clicks a row under `SelectNothing` and asserts
that the model reports nothing selected.

### 9. A gesture has to survive a patch

This one is a defect, and it reaches every program that uses the library
rather than only Cellar.

A controller subscription cancels by calling
`Gtk.widgetRemoveController`, and app-simple cancels and re-subscribes
the whole tree on every state change. So a click that changes the state
takes the `GtkGestureClick` off the widget and puts a new one back.
`GtkGestureClick` counts presses per gesture object, and the new one has
counted none. The second click of a double click arrives with `nPress`
of 1, and no handler written with `onClickPressed` can ever see a double
click, because the first click is what patches.

Cellar hit this first: double-clicking a cell opens the editor, and it
stopped opening. The grid now installs that one gesture by hand through
`afterCreated`, which is the workaround, not the fix.

What to do. Keep the controller across a patch when the attribute is
still there, and rewrite only the callback behind it, the way
`applyHeaderMenu` already rewrites the dispatch behind a menu of
unchanged shape. Removing and re-adding is then only for a controller
that has actually gone.

Test. A property that sends two presses with a patch between them and
asserts that the handler saw a second press, not two firsts.
`EventControllerTest` already drives real presses, and
`prop_controllers_do_not_pile_up` is the test this one sits beside.

## Four more, from the grid in a real window

The grid is Cellar's whole screen: 100 rows of 27 columns, of which about
600 cells are realized at a time. Patching it is slower than the
imperative code it replaced by two orders of magnitude, and items 10 and
11 are where the time goes. Items 12 and 13 are what the rest of the
window needs.

The numbers are CPU time for one patch of Cellar's grid, measured with
`getCPUTime` around the call to `patch`, under Xvfb on this machine:

- An ordinary patch, one cell changed: **34 ms**.
- A patch that rebuilds the columns, which is a sheet opening or a
  column being inserted: **230 ms to 550 ms**.
- The same imperative code before the port: about **1 ms**, because a
  bind was a map lookup and a call to `gtk_label_set_label`.

At 34 ms a keystroke costs two frames, and the loop cannot go quiet
between the 16 ms ticks of Cellar's kernel pump. That is not a
theoretical complaint: it broke Cellar's window test suite, which turned
the loop over until nothing was pending and so never returned.

### 10. A controller is looked up by walking the widget

Item 9 keeps a controller across a patch, which is right, but it finds
the controller again by calling `gtk_widget_observe_controllers` and
walking the list, comparing names. That happens once per controller, per
widget, per patch.

Cellar's cells have one controller each. Taking that controller out of
the markup and adding it by hand cut the heavy patch from 450 ms to
230 ms, so this walk is about half the cost of a patch of a grid.

What to do. Keep the controller where it can be found in constant time.
`g_object_set_data` on the widget, under the same name the library
already generates, answers in one lookup and needs no list walk. Make
sure that a controller added by somebody else is still left alone.

Test. The existing controller properties cover the behavior. Add a
benchmark case in `bench/Benchmark.hs` that patches a container of a few
hundred widgets, each with a controller, so that the cost of this shows
up as a number rather than as somebody's grid feeling slow.

### 11. Every realized row is re-rendered on every patch

`rebindRows` renders and patches every realized row on every patch of
the view, and cancels and re-subscribes each one while it is there. A
grid patch that moves the selection from one cell to the next therefore
renders 600 cells to change 2.

What to do, in rough order of how much it buys:

- Let the caller say when a row has not changed. A function on the
  parameters, such as `rowVersion :: item -> Int` or an `Eq` constraint
  on `item`, lets `rebindRows` skip a row whose item is the same value
  it drew last time. Cellar's rows are plain data, so this is the whole
  problem solved for the common case.
- Do not cancel and re-subscribe a row that was not re-rendered.
- Build the collected attributes once per row rather than once per
  patch, since `collectAttributes` allocates a hash map for every cell.

Test. `bench/Benchmark.hs`, with a column view of a few hundred rows,
patched with one item changed and then with all of them changed. The two
should not cost the same, and today they do.

Two things were tried on Cellar's side first, and neither is worth
doing, which is the reason this item is the library's. Taking the three
attributes that never change out of each cell's markup and setting them
once at creation left the numbers where they were: 45 ms against 36 ms
for an ordinary patch, and 381 to 537 ms against 376 to 481 ms for a
heavy one, which is noise in both directions. Skipping the patch when
the model has not changed skipped nothing at all in that run, because
everything that asked for a patch really had changed something. So the
cost is not in the number of attributes a cell carries. It is in doing
any of this per realized row, per patch.

### 12. An Adwaita header bar as a container

Cellar's header bar is an `AdwHeaderBar` with a title widget and buttons
packed at the start and the end. The core package has that for
`Gtk.HeaderBar`, in `Container/HeaderBar.hs`, and the Adwaita package has
no equivalent, so the header bar is the one part of Cellar's window that
cannot move across yet.

What to do. `GI.Gtk.Declarative.Adwaita.HeaderBar`, an `IsContainer`
instance in the shape of the GTK one, over `adw_header_bar_pack_start`
and `adw_header_bar_pack_end`, plus a `titleWidget` slot for
`adw_header_bar_set_title_widget`.

### 13. A toolbar view with more than one bar per end

My own specification for item 7a said one top bar and one bottom bar,
"until something needs it". Cellar needs three top bars: the header bar,
the tab bar, and the cell bar. Cellar adds its own to the Blueprint one
by hand at the moment, which is fine for a window that is half declared
in XML and no good for one that is not.

What to do. Give `Adw.ToolbarView` an `IsContainer` instance whose child
type says which end a bar belongs to, in the shape of
`Container/ActionBar.hs`, which already has start, centre, and end
children. Keep the content child as `IsBin`.

## What items 10 and 11 bought

Measured the same way as above, with `getCPUTime` around `patch`, after
both landed and after Cellar's rows were changed to carry what their
cells say so that `rowUnchanged = Just (==)` is honest:

- One cell edited, which is the case that matters: **34 ms to under
  1 ms**.
- A patch where every row on screen really did change, such as a
  workbook opening: **34 ms to 16-30 ms**.
- A patch that rebuilds the columns: **230-550 ms to 141-172 ms**.

The grid is no longer the slow part of Cellar. Thank you for both.

One thing for whoever writes the documentation: `rowUnchanged` needs the
caller to make the item hold everything the row draws from, and Cellar's
first version did not -- its items were row numbers and the renderers
read the sheet through a closure. The haddock says this, and it is worth
an example as well, because the failure it prevents is a row that
silently stops repainting.

## 14. A reference to an Adwaita widget

Cellar's header bar and tab bar are declarative now, and items 12 and 13
were what they needed. One small thing was missing.

`AdwTabBar` shows the tabs of an `AdwTabView`, which it holds in its
`view` property: a widget-valued property pointing at a widget somewhere
else in the window, exactly what `GI.Gtk.Declarative.References` is for.
That module covers the GTK cases, `switcherStack` and the rest, and the
Adwaita package has none.

Cellar points the bar at the view with `afterCreated` at the moment,
which works only because the view is not in the same tree: it is still
the window's, built by the Blueprint file. When Phase 4 puts both in one
tree, a reference by name is what this wants:

```haskell
widget Adw.TabBar [tabBarView "sheet-tabs"]
```

What to do. `GI.Gtk.Declarative.Adwaita.References`, with `tabBarView`
over `adw_tab_bar_set_view`, in the shape of the GTK module. Anything
else in libadwaita of that shape can go in beside it, though this is the
only one Cellar needs.

Not urgent. Cellar's workaround holds until Phase 4, and Phase 4 is the
next thing after this.

## After the loop changed hands

Cellar's window is now one state value, one view function and one
update, run by `runInApplication` inside the `AdwApplication` Cellar
already made. Everything asked for above was used, and all of it worked
as written: the toolbar view with its three top bars, the Adwaita header
bar and its title slot, the toast overlay as a bin, the keyed tab view
with its close protocol, `afterCreated`, `rowUnchanged`, and
`SelectNothing`. Two small things are left, and neither blocks anything.

### 15. A start that hands back what it started

`startInApplication` is the right function and its haddock says so.
What it does not do is let the caller do anything when the loop ends,
and Cellar has something to do there: stop the kernel process and drop
the file monitors. So Cellar copies the body of `startInApplication` --
hold the application, run in a thread, release on the main loop -- with
its own two lines in the middle.

What to do. Have `startInApplication` answer with the
`Async.Async state` it started. A caller that wants nothing can ignore
it, and a caller with something to tear down can wait on it.

One thing for the haddock, because the failure mode is quiet. Calling
`runInApplication` from a thread of your own without holding the
application does not fail where you did it. The application returns from
`activate` holding no window, quits, and what you see is
`Gtk-CRITICAL **: New application windows must be added after the
GApplication::startup signal has been emitted` followed by a window that
never appears. It cost an hour here. The existing note says to use
`startInApplication`; saying what happens if you do not would have
saved it.

### 16. A toast without a handle, one day

`Adw.ToastOverlay` is a bin, which is all Cellar needs to put one in the
window. Showing a toast is another matter: `adw_toast_overlay_add_toast`
wants the overlay, so Cellar catches it with `afterCreated` and keeps it
in a reference, which is the one widget handle left in a window that is
otherwise a function of its state.

A `toasts` parameter in the shape of `closeAnswer` -- a command the view
acts on once and the state then clears -- would close that last gap.
Not urgent: a toast is a thing that happens rather than a thing that is,
so the handle is defensible. Worth a thought if the Adwaita package ever
grows a params record for the overlay.

### 14 again, for the record

The reference to an `AdwTabBar`'s view was needed exactly where it was
predicted to be, once the bar and the view were in one tree. Cellar
carries it locally in the meantime, and it is four lines:

```haskell
tabBarView :: Text -> Attribute Adw.TabBar event
tabBarView = reference $ \bar target -> case target of
  Nothing -> Adw.tabBarSetView bar (Nothing :: Maybe Adw.TabView)
  Just widget' -> Adw.tabBarSetView bar =<< Gtk.castTo Adw.TabView widget'
```

That is the whole of it, so the Adwaita module is a home for it rather
than work.

## Items 14, 15 and 16, as they landed

Taken into Cellar on 2026-09-12.

`startInApplication` handing back its `Async` is what Cellar needed:
starting the loop and waiting on it to stop the kernel and drop the file
monitors is four lines now, with no copy of the library's own body in
the middle.

`GI.Gtk.Declarative.Adwaita.References.tabBarView` replaced the local
copy, so the tab bar names the view it shows in the same way a stack
switcher names its stack, and `Cellar.App.View` has no `reference` of
its own any more.

That leaves item 16, the toast, which nobody needs to do anything about:
a toast is a thing that happens rather than a thing that is, and
catching the overlay with `afterCreated` is a fair way to say so.
