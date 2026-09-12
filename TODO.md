# What is left

The GTK 4 port is in place: the library, the examples, and both test
suites are green. This file lists what is not done yet, in the order I
would do it. Cross items off as they land.

## 1. Event controllers (in progress)

GTK 4 moved keyboard, pointer, and gesture handling out of widget
signals and into `GtkEventController` objects. The `on` and `onM`
functions only reach GObject signals, so an application cannot handle a
key press or a click gesture declaratively. GTK 3 did this with
`#keyPressEvent` and `#buttonPressEvent`, and both are gone.

## 2. Model-based views

`ListView`, `ColumnView`, `GridView`, and `DropDown` take a
`GListModel` and a factory that makes a widget for each row, rather
than child widgets. None of them are supported. `ListBox` and `FlowBox`
are the supported widgets of that shape, and they hold real child
widgets, so the patching model fits them.

This one needs a design decision first: a declarative list over a model
is a different thing from a declarative tree of widgets.

## 3. Widgets that hold a reference to another widget

`StackSwitcher` and `StackSidebar` need the `Stack` they control.
`Window` takes a title bar widget through `gtk_window_set_titlebar`.
Neither can be written as an attribute today, because an attribute
takes a value, not a declarative widget. `CustomWidget` is the only way
to reach them now.

## 4. The cabal build path

Everything here is built by calling GHC directly, through the Makefile.
`cabal build all` and `cabal test all` have never run. The module lists
in the cabal files do match the files on disk, but the dependency
bounds are unproven.

## 5. Housekeeping

- `gi-gtk-declarative/src/GI/Gtk/Declarative/Markup.hs` is an empty
  stub that no cabal file names. Delete it.
- `docs/requirements.nix` and the files next to it still pin the 2021
  MkDocs environment. Nothing builds the documentation now, and the
  step that did was dropped from the CI workflow.
- `gi-gtk-declarative/bench/Benchmark.hs` is ported to GTK 4 but has no
  cabal stanza, so it never compiles. Either wire it up with criterion
  or delete it.
- `hie.yaml` does not name the test directories, so an editor loads the
  library but not its tests.
