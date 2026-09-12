# Containers

Containers are widgets that may contain multiple child widgets. Some
examples of such widgets are `Box`, `ListBox`, and `Stack`.

Just like single widgets and bins, the `container` function takes as
arguments a widget constructor and a list of
[properties](../attributes/properties.md). The third argument however,
is a collection of child widgets.

GTK 4 removed `GtkContainer`, so each container has its own way of
adding, replacing, and removing children. This library names those
operations in its own `IsContainer` class, and `container` accepts any
widget with an instance of it. To support a container this page does not
name, write an `IsContainer` instance for it.

## Container and Children Types

Different container widgets use different types to help you construct
a valid widget hierarchy. These types are enforcing the existing GTK
widget rules, that otherwise would be printed as warnings or errors.

Things that vary between container widget types are:

* The types of their child widgets
* The type of collection used to pass the children as a parameter

Several of these child types use the same field names, so `GI.Gtk.Declarative`
only re-exports some of them. Import the module of the container you use,
for example `GI.Gtk.Declarative.Container.Grid`, to get its child type and
child properties.

## Box

In the case of `Box`, the collection of child widgets has type
`[BoxChild event]`.

``` haskell
container Box []
  [ BoxChild defaultBoxChildProperties (widget Button [])
  , BoxChild defaultBoxChildProperties (widget CheckButton [])
  ]
```

As `BoxChildProperties` is a record, it's easy to override the
defaults with custom values, specifying how the child sits in the box.

``` haskell
container Box []
  [ BoxChild defaultBoxChildProperties { padding = 10 }
      (widget Button [])
  , BoxChild defaultBoxChildProperties { expand = True }
      (widget CheckButton [])
  ]
```

GTK 4 dropped the per-child packing properties that GTK 3 had, so these
values are applied to the child widget itself, along the orientation of
the box:

`expand`

:   Sets `hexpand` or `vexpand` on the child.

`fill`

:   Sets `halign` or `valign` on the child to `FILL` when true, and to
    `CENTER` when false.

`padding`

:   Sets the margins on the two sides of the child that face its
    neighbours.

For convenience, widgets can be wrapped in `BoxChild` values
automatically using the default properties.

``` haskell
container Box []
  [ widget Button []
  , widget CheckButton []
  ]
```

## Grid

`Grid` is similar to `Box`, except that the child widgets occupy
a grid (possibly taking up multiple cells) instead of being arranged
in a simple line.

The collection of child widgets has type `[GridChild event]` and a
`GridChildProperties` value specifies size and location in the grid.

``` haskell
container Grid []
  [ GridChild defaultGridChildProperties
      (widget Label [#label := "Input"])
  , GridChild defaultGridChildProperties { leftAttach = 1 }
      (widget Entry [#hexpand := True])
  ]
```

## ListBox and FlowBox

The collection of child widgets used with `ListBox` is of type `[Bin
ListBoxRow event]`, where `ListBoxRow` is the regular constructor
defined in the [gi-gtk][] package. Instead of accepting any `[Widget
event]`, the type constrains its usage to only accept proper
`ListBoxRow` widgets as children.

``` haskell
container ListBox []
  [ bin ListBoxRow [] (widget Button [])
  , bin ListBoxRow [] (widget CheckButton [])
  ]
```

`FlowBox` works the same way, with `FlowBoxChild` bins as children.

``` haskell
container FlowBox []
  [ bin FlowBoxChild [] (widget Button [])
  , bin FlowBoxChild [] (widget CheckButton [])
  ]
```

## Paned

The `Paned` widget has two panes, which contain one widget each. While
`Paned` widgets can be constructed using the `container` function, the
smart constructor `paned` is recommended. It takes a list of attributes,
along with two `Pane` values.

``` haskell
paned
  [#wideHandle := True]
  (pane defaultPaneProperties { resize = True } $
    widget Label [#label := "Left"])
  (pane defaultPaneProperties { resize = True, shrink = False } $
    widget Label [#label := "Right"])
```

Each `Pane` is constructed using the `pane` function, which takes a
`PaneProperties` value and a child widget. The first pane becomes the
start child of the GTK widget, and the second becomes the end child. The
pane properties set the `resize` and `shrink` flags for that side.

## Notebook

The `Notebook` widget has multiple children - called "pages" - and
tabs that allow you to view one page at a time. You should construct
Notebooks with the `notebook`, `page`, and `pageWithTab` functions.

``` haskell
notebook []
  [ page "First tab label" (widget Label [#label := "First tab content..."])
  , pageWithTab
      (widget Button [#label := "Using a button as the tab label widget"])
      (widget Label [#label := "Second tab content..."])
  ]
```

## Stack

A `Stack` shows one of its children at a time. Each child has a name,
which is what `#visibleChildName` selects, and an optional title, which
is what a `GtkStackSwitcher` shows.

``` haskell
container Stack [#visibleChildName := "first"]
  [ StackChild
      defaultStackChildProperties { name = "first", title = Just "First" }
      (widget Label [#label := "The first page."])
  , StackChild
      defaultStackChildProperties { name = "second" }
      (widget Label [#label := "The second page."])
  ]
```

A stack has no notion of a child's position, so a replaced child is
added back at the end.

## HeaderBar and ActionBar

A `HeaderBar` packs its children at the start, at the end, or in the
middle as the title widget.

``` haskell
container HeaderBar []
  [ headerBarStart (widget Button [#iconName := "go-previous-symbolic"])
  , headerBarTitle (widget Label [#label := "The title"])
  , headerBarEnd (widget Button [#iconName := "open-menu-symbolic"])
  ]
```

An `ActionBar` is the same idea at the bottom of a window, with
`actionBarStart`, `actionBarCenter`, and `actionBarEnd`.

## CenterBox

A `CenterBox` has three slots, and keeps the middle one centered. The
`centerBox` function takes the attributes and one widget for each slot.

``` haskell
centerBox []
  (widget Label [#label := "Start"])
  (widget Label [#label := "Center"])
  (widget Label [#label := "End"])
```

## Fixed

A `Fixed` places each child at the position you give it, in pixels.

``` haskell
container Fixed []
  [ FixedChild (FixedChildProperties 10 20) (widget Label [#label := "Here"])
  , FixedChild (FixedChildProperties 80 40) (widget Label [#label := "There"])
  ]
```

## Overlay

An `Overlay` draws its later children on top of the first one.

``` haskell
container Overlay []
  [ widget Picture [#file := background]
  , widget Label [#label := "On top", #halign := AlignEnd]
  ]
```

[gi-gtk]: https://hackage.haskell.org/package/gi-gtk
