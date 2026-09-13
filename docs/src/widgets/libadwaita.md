# libadwaita

libadwaita is GNOME's widget library on top of GTK 4: the window and
the rows a GNOME application is made of, and the style that goes with
them. Its widgets live in a package of their own,
`gi-gtk4-declarative-adwaita`, because the core package depends on GTK
and on nothing else.

Add the package to your `build-depends`, and call `Adw.init` before you
build a widget. An `AdwApplication` calls it for you.

``` haskell
import qualified GI.Adw as Adw
import           GI.Gtk.Declarative.Adwaita.Bin ()
import           GI.Gtk.Declarative.Adwaita.Slots
import           GI.Gtk.Declarative.Adwaita.TabView
```

## Windows and the other single-child widgets

`Adw.ApplicationWindow`, `Adw.Window`, `Adw.ToastOverlay`, `Adw.Bin`,
`Adw.StatusPage`, `Adw.Clamp`, `Adw.Dialog`, and `Adw.ToolbarView` hold
one child each, so each is used with `bin`:

``` haskell
bin Adw.ApplicationWindow [#title := "Cellar"]
  (bin Adw.ToolbarView
    [ toolbarTopBar (container Adw.HeaderBar [] []) ]
    theSpreadsheet)
```

`GI.Gtk.Declarative.Adwaita.Bin` exports nothing. It is imported for
its instances, which is what makes `bin` accept these widgets.

An `AdwApplicationWindow` holds its child in its *content* property
rather than in the window's own child property, and the two are not the
same: setting the wrong one replaces the layout libadwaita put there,
which GTK reports as a warning at run time rather than as an error. The
instance calls `adw_application_window_set_content`, so this is a
mistake a program using it does not make.

## The bars of a toolbar view

A toolbar view holds its content as a child, and one bar at each end in
a slot:

``` haskell
bin Adw.ToolbarView
  [ toolbarTopBar (container Adw.HeaderBar [] [])
  , toolbarBottomBar (container Gtk.ActionBar [] [])
  ]
  theContent
```

A view with more than one bar at an end is a container instead, where
every child says where it goes:

``` haskell
container Adw.ToolbarView []
  [ toolbarTop (container Adw.HeaderBar [] [])
  , toolbarTop (widget Adw.TabBar [])
  , toolbarContent theGrid
  , toolbarBottom (container Gtk.ActionBar [] [])
  ]
```

The bars appear in the order they are given, top to bottom at each end.
The two forms say the same thing, so pick one: a view is a `bin` or a
`container`, not both.

## The header bar

An `AdwHeaderBar` is a container, whose children go at the start or at
the end, and whose title is a property:

``` haskell
container Adw.HeaderBar
  [titleWidget (widget Adw.WindowTitle [#title := name])]
  [ headerBarStart (widget Gtk.Button [#iconName := "document-open"])
  , headerBarEnd (widget Gtk.MenuButton [])
  ]
```

A header bar with no `titleWidget` shows the window's title, which is
what libadwaita does on its own.

The names in `GI.Gtk.Declarative.Adwaita.HeaderBar` are the names
`GI.Gtk.Declarative.Container.HeaderBar` uses for the GTK header bar, so
a module that uses both wants a qualified import of one of them.

## Tabs

`AdwTabView` holds pages, and a page holds a widget and a title. Each
tab carries a key of your own choosing, which is how one render is
matched with the next:

``` haskell
tabView []
  defaultTabViewParams
    { tabs       = [ Tab "sheet-1" "Budget" (sheet budget)
                   , Tab "sheet-2" "Notes"  (sheet notes)
                   ]
    , selected   = Just "sheet-1"
    , onSelected = Just SheetChosen
    }
```

A tab that keeps its key keeps its page, and the widget in it is
patched where it stands rather than built again. A key that is new is
appended, a key that is gone is closed, and the pages end up in the
order the vector is in. `selected` is a command, like the commands of
the [model views](model-views.md): it is carried out when it differs
from the render before, and a selection the markup asked for does not
come back as an event.

The view is the tabs and nothing else. An `AdwTabBar` or an
`AdwTabOverview` is a widget of its own, pointed at this one with its
`view` property, for which there is
[`reference`](../attributes/properties.md).

### Closing a tab

A program usually wants to ask something before a tab goes: whether to
save it, say. So a close from the tab's own button is a question rather
than an act.

``` haskell
tabView []
  defaultTabViewParams
    { tabs        = sheets model
    , onClosePage = Just AskAboutClosing
    , closeAnswer = pendingAnswer model
    }
```

The view emits `onClosePage` with the key and holds the page open. The
program asks whatever it needs to ask, and the answer comes back in a
later render, in `closeAnswer`, as the key and whether the tab goes. A
program that says yes takes the tab out of `tabs` in the same render,
which is what a program does once it knows the answer.

A view with no `onClosePage` has nobody to ask, so a close from the
button does nothing at all. Taking a tab out of `tabs` is what closes
it, and that never asks.

`onReordered` reports every key, in their new order, when somebody
drags a tab somewhere else.

## The rows

`Adw.ActionRow`, `Adw.PreferencesRow`, and the rows like them are
widgets with properties, so they need nothing from this package:

``` haskell
container Gtk.ListBox []
  [ widget Adw.ActionRow [#title := name, #subtitle := path]
  | (name, path) <- recent
  ]
```

A GTK list box takes any widget as a child and wraps what is not a row
in a row of its own, which is what lets an `AdwActionRow` go in one.
