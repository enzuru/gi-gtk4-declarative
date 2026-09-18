# Properties

GTK widgets, being built on the GObject framework, have
properties. These are key/value pairs that can be get and set
generically. This package uses `OverloadedLabels` to declare
properties and their values for GTK widgets.  There are many
properties available for GTK widgets. To find them, use the
[gi-gtk][] documentation. Each widget module lists its properties in
the bottom of the Haddock page.

## Properties in the Attributes List

In gi-gtk4-declarative, the list passed to widgets is not a list of
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

## Properties a person can change

A property declared with `:=` is compared with what the markup said
last time, and set when the two differ. That is enough for a property
only the program changes. It is not enough for one a person changes.

Take an entry whose text comes from the state:

``` haskell
widget Entry [#text := query state, on #changed Typed]
```

Somebody types. The entry now says something the state does not. The
update declines the change, or corrects it, or is slow, and the next
render declares what it declared before. The declared value has not
changed, so nothing is set, and the entry keeps the typing. What is on
the screen and what the program believes are two different things from
then on, and nothing is thrown, logged or otherwise said about it.

Declare such a property with `holding` instead. It is read back off the
widget and set whenever the two disagree:

``` haskell
widget Entry [holding #text (query state), on #changed Typed]
```

These are the properties this happens to, and the list is short:

- `#text`, on an entry and an entry row
- `#active`, on a switch, a switch row, a check button and a toggle
  button
- `#value`, on a range and a spin row

A choice of one out of several is
`GI.Gtk.Declarative.Adwaita.ToggleGroup`, which holds itself and needs
nothing here.

`holding` costs a read of the property on every patch, which is why it
is asked for rather than assumed. The value read and the value declared
have to be one type, so a property whose getter answers `Maybe` where
its setter takes a bare value cannot be held. No property a person
changes is shaped like that.

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

## Pointing at Another Widget

Some widgets work on a widget they do not hold. A `StackSwitcher`
switches a `Stack`, but the stack lives wherever the layout puts it,
which in the usual arrangement is the window's body while the switcher
is in its title bar. A slot cannot say that, because a slot holds a
widget of its own.

Name the one and point at it from the other:

``` haskell
bin Window
  [ titlebar $ container HeaderBar []
      [ headerBarTitle (widget StackSwitcher [switcherStack "pages"]) ]
  ]
  (container Stack [#name := "pages"] pages)
```

The name is the widget's GTK name, which is what a CSS `#id` selector
matches and what a GtkBuilder file calls an id. A widget with no name of
its own answers with the name of its class, so pick a distinctive one.

`GI.Gtk.Declarative.References` names these:

- `switcherStack`, for a stack switcher
- `sidebarStack`, for a stack sidebar
- `keyCaptureWidget`, for a search bar
- `mnemonicWidget`, for a label
- `defaultWidget`, for a window

A reference is resolved on the next turn of the main loop, once when the
whole tree is built and again after each patch, because the widget it
names may have been replaced. It waits because a widget that names
another is often built before it, and a lookup at that moment would find
nothing.

A running application never notices the wait, because a turn of the loop
comes before anything a person can do. A test does: read the property
straight after building the tree and it is not set yet, so let the loop
turn once first.

A name that matches nothing leaves the property unset and is reported as
a warning through GLib.

For a property this module does not name, use `reference` with the
setter from gi-gtk:

``` haskell
reference Gtk.searchBarSetKeyCaptureWidget "the-window"
```

## Reaching the Widget

Some things GTK offers have no declarative form at all: adding a style
provider to the display, taking the keyboard focus, putting a gesture on
a widget the library does not hand you. `afterCreated` is the way out
for those. It takes an action on the underlying GTK widget:

``` haskell
widget Label [afterCreated (\label -> Gtk.widgetGrabFocus label)]
```

It runs once, when the widget has been built and its children are in
place, and a patch does not run it again. So whatever it does has to be
something that survives the widget being patched, or something the
action itself keeps an eye on.
