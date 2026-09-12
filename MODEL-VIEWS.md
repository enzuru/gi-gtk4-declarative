# Declarative model-based views

This answers item 1 of `TODO.md`, and it is written against one case:
Cellar's spreadsheet grid, which is 932 lines of imperative
`GtkColumnView`. The same machinery covers `ListView`, `GridView`, and
`DropDown`.

## Why the tree model does not fit

Every other widget in this library holds its children. The library
creates them, patches them, and subscribes to them, and the state tree
mirrors that shape.

A model-based view holds no children. It holds a `GListModel` and a
`GtkListItemFactory`. The view creates a cell widget when a row scrolls
into sight, binds it to a position, unbinds it when the row leaves, and
binds the same widget to another position later. The library never sees
a fixed list of children to diff.

So the work is not a new `IsContainer` instance. It is a second
patching path, for widgets that are built on demand and recycled.

## The six pieces

### 1. An item model that carries Haskell values

`GListModel` holds GObjects, and a Haskell value is not one.

Two ways exist. The first derives a GObject that holds the value.
`Data.GI.Base.GObject` in haskell-gi 0.26 does this, and it needs no C.
The second keeps the values in Haskell and gives the model nothing but
positions. Cellar takes the second way today: a `GtkStringList` of row
numbers stands in for the rows, and the cell contents are looked up at
bind time.

Take the second way. The view keeps a `Vector item` in its internal
state, and a bind reads the index out of its own stand-in object rather
than asking for its position. Reading the stand-in is what lets a
sorting or filtering model sit between the rows and the view later:
position `n` in the view is not index `n` in the vector once anything
reorders them. No subclass, no `GValue` marshalling, and the model
changes only when the row count changes.

### 2. A row renderer, and per-row state

The caller writes `item -> Widget event`, and the library runs it
through `create` and `patch`.

Keep a record for each realized list item: the markup it currently
shows, its `SomeState`, and its `Subscription`. Hold the records in an
`IORef` map keyed by the `GtkListItem` or `GtkColumnViewCell`.

- On setup, store nothing. There is no item yet.
- On bind, create the markup for the new position. If the list item has
  no state, call `create` and set the child. If it has state, call
  `patch`, and set the child again if the result is `Replace`.
- On unbind, cancel the subscription and keep the widget, so that
  recycling still works.
- On teardown, cancel the subscription and drop the record.

This is the whole benefit of the feature. The cell becomes a
declarative value instead of a widget somebody paints by hand.

A patch of the view itself has to show the rows again. If an item says
something new while the number of items stays the same, the model has
not changed, so GTK has no reason to bind anything, and the row would
keep what it had. So a patch walks the rows on screen and patches each
against the item it now stands for.

### 3. The event sink

`subscribe` runs after `create`, and rows bind both before and after it.
A row cannot be subscribed to through the normal path, because the
callback does not exist yet when the first rows bind.

Hold the callback in an `IORef (event -> IO ())` in the view's internal
state, set to a no-op at creation. `subscribe` writes the real callback
and returns a cancellation that writes the no-op back. Every row
publishes through that reference.

### 4. Columns

`GtkColumnViewColumn` is a GObject and not a widget, and `SomeState`
requires `Gtk.IsWidget`, so a column cannot go in the state tree. Diff
the columns inside the view's internal state instead.

Ask the caller for a key per column. Match old columns against new ones
by key. On a match, set `title`, `resizable`, `fixed-width`, and
`visible`. On a new key, call `gtk_column_view_insert_column`. On a
dropped key, call `gtk_column_view_remove_column`.

The key is what makes an inserted spreadsheet column cheap. Without it,
an insert at position B rebuilds every column to its right, which is the
bookkeeping Cellar's grid does by hand today.

### 5. Commands that are not properties

Scrolling and selection are actions rather than properties, and the
library has no way to express an action.

Make them parameters. Give the view a `scrollTo :: Maybe Word32`, and
call `gtk_column_view_scroll_to` when the value differs from the value
in the last patch. Carry the selected position the same way, through
`GtkSingleSelection`. A patch that repeats the value does nothing, which
is what makes this safe in a `view` function that runs on every state
change.

### 6. Reading state back

Emit events for what the application cannot know otherwise: the
selection changed, a row was activated, and a column was resized. The
last one comes from `notify::fixed-width` on the column, and Cellar
needs it to persist the column layout.

## A sketch of the API

```haskell
data Column item event = Column
  { columnKey      :: Text
  , columnTitle    :: Text
  , columnAttrs    :: Vector (ColumnAttribute event)
  , columnRenderer :: item -> Widget event
  }

columnView
  :: Vector (Attribute Gtk.ColumnView event)
  -> Vector (Column item event)
  -> ColumnViewParams event      -- scrollTo, selected, onSelect, onActivate
  -> Vector item
  -> ColumnView item event
```

`CustomWidget` cannot carry this, which is the one thing in this plan
that turned out to be wrong. Its `customParams` are untouched by the
`Functor` instance that maps events, so a `Column` holding
`item -> Widget event` would never be remapped, and a view inside an
`fmap` would emit the wrong events. `MenuModel` hit the same wall and
grew its own `Patchable` and `EventSource`, and a view does the same.

Which raises a second thing. The state a view keeps has to name the type
of the events its rows emit, so that `patch` can recognise it again, and
that type has to hold still while `fmap` changes what the view is read
as. So the two are separate: the markup and the state are typed by the
events the rows emit, and the value carries a function from those to
whatever the view is read as. `fmap` composes that function and leaves
the state's type alone.

One more, from the bindings rather than the design.
`gtk_list_view_new` takes over the model and the factory handed to it,
which leaves the Haskell values disowned and the bindings warning about
every later use. Build the view with `Gtk.new` and hand it the model and
the factory through the setters, which borrow.

## What stays imperative afterwards

Say both of these in the documentation, because a user who expects a
fully declarative grid finds them the hard way.

GTK has no header factory. `gtkcolumnviewcolumn.h` in GTK 4.22 offers
`title`, `resizable`, `fixed-width`, and `header-menu`, and no way to
supply a header widget. A program that wants a gesture on a column
header, as Cellar does for column dragging, still reaches the built-in
header widget by hand.

Per-cell colors stay a stylesheet problem. A cell names its CSS classes
declaratively, but something has to put those classes in a provider, and
that is the application's job.

## Order of work

1. `ListView` first. One factory, no columns, and the row renderer, the
   per-row state, and the event sink all appear there. **Done**, in
   `GI.Gtk.Declarative.ModelView.ListView`, on the machinery in
   `GI.Gtk.Declarative.ModelView.Internal`.
2. `ColumnView` on the same machinery, plus the column diff. **Done**,
   in `GI.Gtk.Declarative.ModelView.ColumnView`. Columns are matched
   across a render by a key of the caller's choosing, so a column that
   keeps its key keeps its widget, its width, and its cells.
3. `GridView` and `DropDown`, which are the same again with a different
   widget.
4. Cellar's grid, last.

Test each step the way `CustomWidgetTest` does, with one difference
that matters: the window has to be presented. A view that is not on
screen has no size, a view with no size has no rows, and a test of rows
that were never built passes for the wrong reason. Scrolling is the case
that matters after that, because it is the one that exercises recycling.
Drive it by setting a large item count and calling
`gtk_column_view_scroll_to`.

## What the tests have to do

A view that is not on screen has no size, and a view with no size has
no rows, so every test here presents its window first. Activating a row
needs no mouse: GTK puts a `list.activate-item` action on the view, and
a test hands it a position.

## Two numbers to get before committing

Measure the bind path. Cellar binds a cell on every scroll frame, and
`paintCell` is a few map lookups. A declarative bind builds a markup
value and diffs its attributes. Add a bind-heavy case to
`bench/Benchmark.hs` and compare the two, because a spreadsheet scrolls
hundreds of cells at a time.

Count what Cellar's grid loses. The per-column index references,
`reletterColumns`, the realized-cell list, and `paintCell` all go. The
palette, the header drag, and the `Command` type stay. The module lands
at roughly a third of its present size, and the rest of the shell reads
it as one value.

The module itself is 400 to 600 lines, plus tests. That is the largest
single piece of work in this repository.
