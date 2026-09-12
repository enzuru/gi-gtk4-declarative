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

## 2. Widgets that point at another widget

`StackSwitcher` and `StackSidebar` need the `Stack` they control, and a
`SearchBar` needs the widget whose keys it captures. These are not
widgets a parent owns: the stack lives somewhere else in the layout,
and the switcher only points at it.

A slot cannot express that, because a slot holds a widget of its own.
What would is either a combined constructor, which builds the switcher
and the stack together and wires them up, or a way to name a widget in
one place and refer to it in another. The combined constructor is the
smaller of the two and covers the cases that come up.

## 3. Housekeeping

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

- Widget-valued properties. `slot`, and `titlebar`, `frameLabel`,
  `expanderLabel`, `listBoxPlaceholder`, and `menuButtonPopover` in
  `GI.Gtk.Declarative.Slots`. The widget in a slot is created, patched,
  subscribed to, and emptied like any other, which is what the four
  tests in `GI.Gtk.Declarative.SlotTest` check.
- The cabal build path. `cabal build all` and `cabal test all` both run,
  and both test suites pass through them. Four upper bounds were wrong
  and excluded what is installed: `containers`, `data-default-class`,
  `haskell-gi`, and `haskell-gi-base`. The bounds `cabal check` asked
  for are in place.
- Event controllers. `onController` and `onControllerM` add a controller
  to a widget for as long as the widget is subscribed to, and
  `GI.Gtk.Declarative.EventController` names the common ones, from
  `onKeyPressed` to `onDragUpdate`. A real key press and a real click
  are tested through `tests/gui-input.sh`, because nothing in GTK 4 can
  make either of them happen from code.
