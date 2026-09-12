# What is left

The GTK 4 port is in place: the library, the examples, and both test
suites are green. This file lists what is not done yet, in the order I
would do it. Cross items off as they land.

## 1. Model-based views

`ListView`, `ColumnView`, `GridView`, and `DropDown` take a
`GListModel` and a factory that makes a widget for each row, rather
than child widgets. None of them are supported. `ListBox` and `FlowBox`
are the supported widgets of that shape, and they hold real child
widgets, so the patching model fits them.

This one needs a design decision first: a declarative list over a model
is a different thing from a declarative tree of widgets.

## 2. Widgets that hold a reference to another widget

`StackSwitcher` and `StackSidebar` need the `Stack` they control.
`Window` takes a title bar widget through `gtk_window_set_titlebar`.
Neither can be written as an attribute today, because an attribute
takes a value, not a declarative widget. `CustomWidget` is the only way
to reach them now.

## 3. The cabal build path

Everything here is built by calling GHC directly, through the Makefile.
`cabal build all` and `cabal test all` have never run. The module lists
in the cabal files do match the files on disk, but the dependency
bounds are unproven.

## 4. Housekeeping

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

## Done

- Event controllers. `onController` and `onControllerM` add a controller
  to a widget for as long as the widget is subscribed to, and
  `GI.Gtk.Declarative.EventController` names the common ones, from
  `onKeyPressed` to `onDragUpdate`. A real key press and a real click
  are tested through `tests/gui-input.sh`, because nothing in GTK 4 can
  make either of them happen from code.
