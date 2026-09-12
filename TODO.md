# What is left

The GTK 4 port is in place: the library, the examples, and the test
suites are green. Two things are left. Cross items off as they land.

## 1. Model-based views

`ListView`, `ColumnView`, `GridView`, and `DropDown` take a
`GListModel` and a factory that makes a widget for each row, rather
than child widgets. None of them are supported. `ListBox` and `FlowBox`
are the supported widgets of that shape, and they hold real child
widgets, so the patching model fits them.

This one needs a design decision first: a declarative list over a model
is a different thing from a declarative tree of widgets.
`MODEL-VIEWS.md` makes that decision and names the six pieces of work.

## 2. The addresses still point at upstream

The packages are named gi-gtk4-declarative now, but everything that
says where to find them still names owickstrom's project, because that
is whose it is and this fork has nowhere of its own yet. Each of these
needs a decision rather than work:

- `homepage` and `bug-reports`, in both cabal files.
- `source-repository head`, in the library's cabal file.
- `maintainer`, in both cabal files, which still reads the original
  author's name and address. The `author` and `copyright` fields should
  keep his name either way, which the license asks for.
- The documentation link in `README.md`, and the site the documentation
  itself links to, which is built from `docs/` here but published at
  his address.
- The README badges, which were taken out rather than left pointing at
  a package that is not published. Put them back when there is
  something for them to point at.

Two more outside the repository: the `origin` remote is still
`owickstrom/gi-gtk-declarative`, so a push would go at upstream, and the
checkout is still in a directory of the old name.

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
