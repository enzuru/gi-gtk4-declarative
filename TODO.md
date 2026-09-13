# What is left

The GTK 4 port is in place: the library, the examples, and the test
suites are green. Two things are left. Cross items off as they land.

## 1. The last two model-based views

`GridView` and `DropDown` take a `GListModel` and a factory that makes
a widget for each row, as `ListView` and `ColumnView` do, and neither
is supported. The work is the same shape as the two that landed:
`GI.Gtk.Declarative.ModelView.Internal` already holds the row
machinery, so each is a module that makes the widget, sets the model,
and says what its own parameters are. `MODEL-VIEWS.md` has the design.

Nothing needs either one yet, which is why they are here rather than
done.

## 2. The addresses still point at upstream

The packages are named gi-gtk4-declarative now, but everything that
says where to find them still names owickstrom's project, because that
is whose it is and this fork has nowhere of its own yet. Each of these
needs a decision rather than work:

- `homepage` and `bug-reports`, in all three cabal files.
- `source-repository head`, in the library's cabal file.
- `maintainer`, in all three cabal files, which still reads the original
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

- A gesture that lives through a patch. A controller used to come off
  the widget with its subscription, and an application cancels and
  subscribes again on every event, so no handler could ever see the
  second click of a double click. The controller now stays and the
  handler behind it is what the subscription owns.
- A selection mode on both model views. `SelectNothing` builds a
  `GtkNoSelection`, which is what a spreadsheet wants: what is selected
  there is a cell rather than a row.
- The libadwaita widgets. A third package,
  `gi-gtk4-declarative-adwaita`, holding `IsBin` instances for the
  single-child widgets (`Adw.ApplicationWindow` and the rest), the
  header bar and the toolbar view as containers, the two toolbar-view
  bar slots, the reference from a tab bar to its view, and a declarative
  `AdwTabView` whose tabs are matched by a key of the caller's
  choosing. Twenty-eight properties in
  `gi-gtk4-declarative-adwaita/test`, and a
  [documentation page](docs/src/widgets/libadwaita.md).
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
