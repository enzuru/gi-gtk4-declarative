* 0.8.0
    - Port to GTK 4 (gi-gtk 4.x). This is a breaking release; use 0.7 for GTK 3.
    - `run` creates and runs a `GLib.MainLoop`, as GTK 4 removed
      `gtk_main` and `gtk_main_quit`.
    - The window of an `App` is presented with `gtk_window_present` and
      taken down with `gtk_window_destroy`, so `run` and `runLoop` now
      ask for a GTK window.
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
* 0.4.3
    - Bump upper bound on haskell-gi
* 0.4.2
    - Add support for dialogs
    - Assert in 'run' that the program is using the threaded RTS
    - Bug fixes in rendering
* 0.4.1
    - Support any Bin automatically
* 0.4.0
    - Vector over list for child widgets
* 0.3.0
    - List markup
    - Return last state from `run` and `runLoop`
* 0.2.0
    - Require GTK+ windows as top-level widget
* 0.1.0
    - First version of `gi-gtk-declarative`!
    - Basic widget without event handling
    - Support for `Box` and `ScrolledWindow` containers
    - Declarative CSS classes
