* 0.8.0
    - Port to GTK 4 (gi-gtk 4.x). This is a breaking release; use 0.7 for GTK 3.
    - Event controllers: `onController`, `onControllerM`, and the named
      helpers in `GI.Gtk.Declarative.EventController`, since GTK 4 reports
      keys, pointers, and gestures through controllers rather than through
      signals on the widget.
    - Widget-valued properties: `slot`, and the named helpers in
      `GI.Gtk.Declarative.Slots`, which put a declarative widget in a
      window's title bar, a frame's label, and the like.
    - References: `reference`, and the named helpers in
      `GI.Gtk.Declarative.References`, which point a widget-valued
      property at another widget by its name, for the widgets that work
      on a widget they do not hold, such as a stack switcher.
    - `StateTreeNode` carries the state of a widget's slots.
    - `bin` now works with the new `IsBin` class of this library, with
      instances for the GTK 4 widgets that hold a single child, as GTK 4
      removed `GtkBin`.
    - `IsContainer` gained a `removeChild` method, as GTK 4 removed
      `GtkContainer` and `gtk_widget_destroy`.
    - `BoxChildProperties` are applied to the child widget itself, as
      GTK 4 removed child packing properties: `expand` sets hexpand or
      vexpand, `fill` sets the alignment, and `padding` sets the margins.
    - `Pane` properties use the start and end child of `GtkPaned`.
    - New containers: `FlowBox`, `Stack`, `HeaderBar`, `ActionBar`,
      `CenterBox`, `Fixed`, and `Overlay`.
    - `GI.Gtk.Declarative.Container.MenuItem` is replaced by
      `GI.Gtk.Declarative.MenuModel`, which builds a `GMenu` model shown
      by a `PopoverMenuBar` or a `MenuButton`.
    - CSS classes are set with `gtk_widget_add_css_class` rather than
      through a style context, and `StateTreeNode` no longer carries one.
    - Tests cover every container, the menus, and patching, and run
      headless under Xvfb.
* 0.7.0
    - Version bounds compatibility with Stack resolver lts-17.0
    - Replace Travis badge with a Github workflow one.
    - Replace .travis.yml with a Github Actions Workflow.
    - Improved exception handling and async handling in app-simple
    - Fix race condition in app-simple
    - Fix patching of grid child properties.
* 0.6.3
    - Add `Grid` container widget
    - Fix bugs in patching properties for all types of widgets
* 0.6.2
    - Add `Notebook` container widget
* 0.6.1
    - Fix Nix build issue
* 0.6.0
    - Allow dependency haskell-gi-0.23
    - Remove redundant code
* 0.5.0
  - New `CustomWidget` API:
    - easier-to-use internal state
    - pass-through attributes to top widget
* 0.4.0
    - Use `Vector` instead of `[]` for child widgets
* 0.3.0
    - Add user documentation
    - Use record for `BoxChild` properties (breaking change!)
    - Use lists for child widgets instead of `MarkupOf` monad (breaking change!)
    - Add support for `Paned` widget
* 0.2.0
    - Introduce shadow state (breaking change!)
    - Optimized patching (2x-7x faster!)
    - Many bug fixes in patching
    - Reimplement callback conversions
    - Return pairs in declarative event handlers, for non-`()` GTK+ callback return values

* 0.1.0
    - First version of `gi-gtk4-declarative`!
    - Basic widget without event handling
    - Support for `Box` and `ScrolledWindow` containers
    - Declarative CSS classes
