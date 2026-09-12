# Bins

A bin is a widget with exactly one child widget. You construct one with
the `bin` function, given a GTK widget constructor, a list of
attributes, and a child widget.

``` haskell
bin Window [#title := "Example Window"] $
  widget Label [#label := "Nothing here yet."]
```

In some cases, a specific type of bin is the child of another widget. A
`ListBox` takes `ListBoxRow` bins as children.

``` haskell
container ListBox []
  [ bin ListBoxRow [] $ widget Button []
  , bin ListBoxRow [] $ widget CheckButton []
  ]
```

## Which widgets are bins

GTK 4 removed `GtkBin`. Each widget that holds one child now has a
setter of its own, such as `gtk_window_set_child` or
`gtk_frame_set_child`. This library names that pair of operations in its
own `IsBin` class, and `bin` accepts any widget with an instance of it.

These widgets have instances:

- `Window`, `ApplicationWindow`, and `WindowHandle`
- `Frame` and `AspectFrame`
- `Button`, `ToggleButton`, `CheckButton`, `LinkButton`, and `MenuButton`
- `Expander` and `Revealer`
- `ScrolledWindow` and `Viewport`
- `Popover` and `SearchBar`
- `ListBoxRow` and `FlowBoxChild`
- `Overlay`, whose main child this is

To add a bin for a widget this list does not name, write an `IsBin`
instance for it.
