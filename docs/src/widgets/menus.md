# Menus

GTK 4 removed `GtkMenu`, `GtkMenuBar`, and `GtkMenuItem`. A menu is now
a *menu model*: a tree of labels and action names, shown by a widget
such as `PopoverMenuBar` or `MenuButton`.

The `GI.Gtk.Declarative.MenuModel` module keeps the declarative style.
You describe the menu as a tree of `MenuItem` values that carry events,
and the library creates the menu model, the actions behind it, and the
wiring to your event callback.

``` haskell
menuBar []
  [ subMenu "File"
      [ menuSection Nothing
          [ menuItem "Open" Open
          , menuItem "Save" Save
          ]
      , menuItem "Quit" Quit
      ]
  , subMenu "Help"
      [ menuItem "About" About ]
  ]
```

There are three kinds of item:

`menuItem label event`

:   An item you can click. It emits the event.

`subMenu label items`

:   A menu nested in another menu.

`menuSection label items`

:   A group of items, separated from its neighbours, with an optional
    heading.

Use `menuBar` for a menu bar across the top of a window, and
`menuButton` for a button that pops the menu up.

``` haskell
menuButton [#iconName := "open-menu-symbolic"]
  [ menuItem "Preferences" Preferences
  , menuItem "About" About
  ]
```

!!! note

    The items are a `Vector`, as the children and the attributes of
    every widget here are. `OverloadedLists` covers a list literal and
    leaves a list comprehension alone, so a comprehension needs
    `Vector.fromList` around it:

    ``` haskell
    menuSection Nothing (Vector.fromList [ menuItem (label n) (New n) | n <- sizes ])
    ```

!!! note

    A menu bar needs a window that shows one. Put the `menuBar` widget
    in a box, or set the window's `#showMenubar` property when you use a
    `GtkApplication` menu instead.
