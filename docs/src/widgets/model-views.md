# Model-Based Views

`ListView`, `ColumnView`, and the widgets like them hold no children.
They hold a list model and a factory, and build a widget only for the
rows on screen, reusing it for another row when that one scrolls away.
That is what lets them show a hundred thousand rows.

So they take the rows as data, and a function that renders one:

``` haskell
import GI.Gtk.Declarative.ModelView.ListView

listView []
  (defaultListViewParams (\name -> widget Label [#label := name]))
    { rows = names
    , onActivated = Just Chose
    }
```

The rows stay in Haskell. What GTK holds is one small stand-in object
per row, and rendering a row looks it up here.

Put the view in a `ScrolledWindow`. Neither of these scrolls on its own.

## Columns

A column view is the same, with more than one cell per row. A column
says how to render one cell:

``` haskell
import GI.Gtk.Declarative.ModelView.ColumnView

columnView []
  (defaultColumnViewParams
    [ column "name" "Name" (\person -> widget Label [#label := name person])
    , (column "role" "Role" (\person -> widget Label [#label := role person]))
        { columnExpand = True }
    ])
    { rows = people
    , onSelected = Just Chose
    }
```

Each column has a key of your own choosing, which is how a column in
one render is matched with a column in the next. A column that keeps its
key keeps its widget, its width, and the cells under it, so inserting a
column in the middle costs one column rather than all the ones after it.
Changing the order of the keys changes the order of the columns.

## Commands

`selected` and `scrollTo` are commands rather than properties: they say
to do something, not to be something. Each is carried out when the value
differs from the value given in the render before, so a view function
that repeats itself does nothing, and a user who scrolls somewhere else
is not dragged back on the next event.

``` haskell
(defaultListViewParams renderRow)
  { rows = items
  , selected = Just 3      -- selects row 3, once
  , scrollTo = Just 3
  }
```

## Drawing a row again

A patch draws every row on screen again, because the model has not
changed and GTK has no reason to bind anything. A view of six hundred
cells usually has two of them to change, and the other five hundred and
ninety-eight cost the same as the two.

So tell the view when a row has not changed:

``` haskell
(defaultColumnViewParams theColumns)
  { rows = people
  , rowUnchanged = Just (==)
  }
```

The function is given the item a row was drawn from and the item it
would be drawn from now. `True` says the row would come out the same,
so the view leaves it alone: not rendered, not patched, and not
subscribed to again. On a view of a hundred rows of ten columns, a patch
that changes one row costs 1.7 ms with the comparison and 22 ms without
it.

This is a promise about the renderer: that it reads its item and nothing
else. A `renderRow` that also reads, say, which cell is being edited
gives two different rows for two equal items, and the view would show
the older one. Leave `rowUnchanged` as `Nothing` for such a renderer, or
put what it reads in the item.

## Selection

A view selects one row at a time, which is what a list of things to
choose from wants. A view whose rows are not a choice asks for no
selection at all:

``` haskell
(defaultColumnViewParams theColumns)
  { rows = cells
  , selectionMode = SelectNothing
  }
```

Under `SelectNothing` GTK highlights nothing, and `selected`,
`onSelected`, and the selection command do nothing. This is what a
spreadsheet wants: what is selected there is a cell rather than a row,
and the program draws that itself. Activating a row still works, so a
double click and Enter still arrive at `onActivated`.

The selection model is one GTK object or the other, so a view whose
mode changes between renders is built again rather than patched.

## Events

A widget inside a row emits events the same way it would anywhere else.
The view has three of its own:

- `onSelected`, when the selected row changes, whoever changed it
- `onActivated`, when a row is activated, by a double click or by Enter
- `onResized`, on a column, when its width changes

The last one is how an application remembers a column layout the user
arranged.

## Header menus

A column can carry a menu on its header, for what a person does to a
whole column:

``` haskell
(column "name" "Name" renderCell)
  { columnHeaderMenu =
      [ menuItem "Insert before" (InsertBefore "name")
      , menuItem "Remove" (Remove "name")
      ]
  }
```

The items are the declarative ones from
`GI.Gtk.Declarative.MenuModel`, so their events arrive like any other
event here. The menu is built again only when its shape changes, and
the events behind it are always the ones from the latest render.

## What is still done by hand

GTK has no factory for column headers. A header is its title text and
its menu and nothing else, so a program that wants a widget of its own
up there, or a gesture on a header, reaches for the header widget by
hand, with `afterCreated`.

Per-cell colors are a stylesheet matter. A cell can name its CSS classes
declaratively, but something has to put those classes in a provider, and
that is the application's job.

## Two notes

The parameters of a list view and of a column view share field names, so
a module using both wants `DisambiguateRecordFields` or a qualified
import of one of them.

A view that is not on screen has no size, and a view with no size has no
rows. That matters when testing: present the window first, or the test
passes without ever having built a row.
