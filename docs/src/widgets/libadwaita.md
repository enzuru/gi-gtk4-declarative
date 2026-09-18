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

## A window of two panes

An `AdwNavigationSplitView` holds a sidebar and a content page, each of
which is an `AdwNavigationPage`. Neither is a child: both are
properties, so both are slots.

``` haskell
widget Adw.NavigationSplitView
  [ splitViewSidebar (bin Adw.NavigationPage [#title := "Tools"] theList)
  , splitViewContent (bin Adw.NavigationPage [#title := name] thePane)
  ]
```

`AdwOverlaySplitView` is the same shape and takes plain widgets rather
than pages, through `overlaySidebar` and `overlayContent`.

## A dialog

An `AdwDialog` is neither a child nor a property. It is presented over a
widget, and it takes itself down again, so a view has nowhere to say
which dialog is open. `presentedDialog` is that place:

``` haskell
bin Adw.ApplicationWindow
  (  [#title := "Toolchains"]
  <> foldMap (\open -> [presentedDialog (dialogFor state open)]) (dialog state)
  )
  content
```

The dialog lives the life of any other widget in a slot. It is created
with the window, patched while it is open, so that what it shows follows
the state, and subscribed to for its events. When the view stops naming
a dialog, the slot is emptied, and emptying it closes the dialog.

A dialog somebody closed with Escape is already gone, and the slot knows
not to close it twice.

## A settings page

A page of settings is an `AdwPreferencesGroup` holding rows:

``` haskell
container Adw.PreferencesGroup
  [#title := "Board", headerSuffix (widget Gtk.Button [#iconName := "view-refresh"])]
  [ widget Adw.SwitchRow [#title := "Show coordinates", #active := coordinates state]
  , container Adw.ActionRow
              [#title := "Size"]
              [rowSuffix (toggleGroup [] sizes)]
  ]
```

A row with one value and no children is a widget like any other.
`Adw.SwitchRow`, `Adw.SpinRow`, `Adw.EntryRow` and
`Adw.PasswordEntryRow` need nothing of their own, because what they hold
is properties. A preferences group takes them as they are, and so does a
list box.

An `Adw.ActionRow` holds widgets at either end of itself, so it is a
container, with `rowPrefix` and `rowSuffix` for the two ends.

A program with more than one group puts them on an
`Adw.PreferencesPage`, which is a container of groups, and pages go in
an `Adw.PreferencesDialog`, which is a container of pages. Each takes
what it takes and nothing else: a child of the wrong kind fails when the
markup is rendered rather than becoming a warning from libadwaita
afterwards.

An `Adw.ExpanderRow` is a container of the rows it reveals. The switch
in its header is a property a person changes and a program owns, so it
wants `holding`:

``` haskell
container Adw.ExpanderRow
  [ #title := "Nightlies"
  , #showEnableSwitch := True
  , holding #enableExpansion (nightlies state)
  ]
  [widget Adw.EntryRow [#title := "Metadata URL"]]
```

## One choice out of a few

An `AdwToggleGroup` is the widget for a choice from a short list:

``` haskell
toggleGroup []
  defaultToggleGroupParams
    { toggles     = [toggle "9" "9x9", toggle "13" "13x13", toggle "19" "19x19"]
    , active      = Just (sizeName state)
    , onActivated = Just Chose
    }
```

Each toggle has a name, which is what `active` names, what `onActivated`
answers with, and what matches a toggle with the one of the render
before. The group is not a container: what it holds are `AdwToggle`
objects rather than widgets, so they are described here as data.

Use this rather than a row of toggle buttons. A `GtkToggleButton` whose
`active` comes from the markup does not hold together: the markup says
the button is on, somebody clicks it, GTK turns it off, and the next
render says what it said before. The declared value did not change, so
the patch sets nothing, and the button stays off.

A toggle group closes that. It has one `active` for the whole group, and
GTK will not let a click turn the chosen toggle off, which the input
test in this repository clicks twice to make sure of. `active` is also
read back off the group before it is set, so a group that has drifted
from the markup is put back, however it got there.

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

### The tab bar

An `AdwTabBar` shows the tabs of a view it does not hold, so the two are
joined by name, the way a stack switcher is joined to its stack:

``` haskell
container Adw.ToolbarView []
  [ toolbarTop (widget Adw.TabBar [tabBarView "sheets"])
  , toolbarContent (tabView [#name := "sheets"] theTabs)
  ]
```

`GI.Gtk.Declarative.Adwaita.References` has `tabBarView` and
`tabOverviewView`. A name that matches nothing is a warning through
GLib, and leaves the bar showing no tabs.

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
