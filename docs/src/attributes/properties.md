# Properties

GTK widgets, being built on the GObject framework, have
properties. These are key/value pairs that can be get and set
generically. This package uses `OverloadedLabels` to declare
properties and their values for GTK widgets.  There are many
properties available for GTK widgets. To find them, use the
[gi-gtk][] documentation. Each widget module lists its properties in
the bottom of the Haddock page.

## Properties in the Attributes List

In gi-gtk-declarative, the list passed to widgets is not a list of
properties, but a list of _attributes_. The attributes list include
property declarations, [events](events.md), and [CSS classes](css.md).
To declare a property and a value in the attributes list, we use the
`(:=)` operator.

Here we construct a button with a specific text label:

``` haskell
widget Button [#label := "Click Here"]
```

In the following example we declare a `ScrolledWindow`, and set the
horizontal scroll bar policy to _automatically_ decide whether the
scroll bar should be visible:

``` haskell
bin ScrolledWindow [ #hscrollbarPolicy := PolicyTypeAutomatic ]
  someSuperWideWidget
```

As a final example, we declare a `ListBox` with the multiple selection
mode enabled:

``` haskell
container ListBox [ #selectionMode := SelectionModeMultiple ]
  children
```


[gi-gtk]: https://hackage.haskell.org/package/gi-gtk

## Widget-Valued Properties

Some properties hold another widget rather than a value: a window's
title bar, a frame's label, the placeholder a list box shows when it is
empty. These cannot be written with `:=`, because what goes there is a
widget of your own, with its own attributes, children, and events.

The `GI.Gtk.Declarative.Slots` module has them as attributes:

``` haskell
bin Window
  [ #title := "Example"
  , titlebar (container HeaderBar [] [headerBarTitle (widget Label [])])
  ]
  (widget Label [#label := "Nothing here yet."])
```

These are the ones it names:

- `titlebar`, for a window
- `frameLabel`, for a frame
- `expanderLabel`, for an expander
- `listBoxPlaceholder`, for a list box
- `menuButtonPopover`, for a menu button

The widget in such a slot lives the same life as any other. It is
created with its parent, patched in place when it changes, subscribed to
for its events, and taken away when the attribute is gone.

For a widget-valued property this module does not name, use `slot` and
give it a name of your own along with the setter from gi-gtk:

``` haskell
slot "placeholder" Gtk.listBoxSetPlaceholder (widget Label [#label := "Empty"])
```

The name tells one slot from another when patching, so two slots on the
same widget must not share a name.
