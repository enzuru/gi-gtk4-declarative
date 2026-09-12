# What is left

The GTK 4 port is in place: the library, the examples, and the test
suites are green. One thing is left. Cross items off as they land.

## 1. Model-based views

`ListView`, `ColumnView`, `GridView`, and `DropDown` take a
`GListModel` and a factory that makes a widget for each row, rather
than child widgets. None of them are supported. `ListBox` and `FlowBox`
are the supported widgets of that shape, and they hold real child
widgets, so the patching model fits them.

This one needs a design decision first: a declarative list over a model
is a different thing from a declarative tree of widgets.

## Done

- Housekeeping. The dead `Markup.hs` stub is gone, `hie.yaml` names the
  tests and hides the duplicate gi-gtk packages, the benchmark has a
  cabal stanza and a `make bench` target, and the documentation builds
  again from a Nix shell of its own rather than the 2021 MkDocs pin.
- Widgets that point at another widget. `reference`, and `switcherStack`,
  `sidebarStack`, `keyCaptureWidget`, `mnemonicWidget`, and
  `defaultWidget` in `GI.Gtk.Declarative.References`. A widget is named
  with its `name` property and pointed at from elsewhere in the tree.
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
