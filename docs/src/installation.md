# Installation

To install the gi-gtk4-declarative package in your project, follow
these steps and guidelines:

- The gi-gtk4-declarative package builds on
  [gi-gtk](https://hackage.haskell.org/package/gi-gtk) version 4, and
  thus depends on the same libraries. First, follow the instructions on
  how to install the GTK dependencies using your package manager of
  choice over at [the gi-gtk
  README](https://github.com/haskell-gi/haskell-gi#installation). You
  need GTK 4 and the GObject introspection data that comes with it.

- Version 0.8 and later target GTK 4. For GTK 3, use version 0.7 and
  gi-gtk 3.

- Once you have the GTK system libraries installed, it should be a
  regular Haskell package install with Cabal, Nix, or whatever floats
  your boat.

- Executables using gi-gtk4-declarative must be built with the
  `-threaded` option passed to GHC. If you are not seeing a window,
  check this first.


## Cabal Example

Let's look at an example of using Cabal to build a gi-gtk4-declarative
project. It's assumed you're running Cabal 2.x, and that you have an
existing project to work with. If you don't have a project, and you're
unsure how to set one up, have look at [Introduction to
Cabal](https://haskell-at-work.com/episodes/2018-05-13-introduction-to-cabal.html).

### Adding Dependencies

Begin by including

- `gi-gtk`,
- `gi-gtk4-declarative`, and
- `gi-gtk4-declarative-app-simple`

in the `build-depends` list of your library or executable:

    name: your-project
    ...

    executable your-executable
      build-depends:
        gi-gtk
        , gi-gtk4-declarative
        , gi-gtk4-declarative-app-simple
        , ...
      ghc-options:      -threaded
      default-language: Haskell2010

Note that `gi-gtk4-declarative-app-simple` is not strictly required,
unless you want to write your application using the
[App.Simple](app-simple.md) architecture.

### Installing and Building

Install dependencies and build your executable:

``` bash
cabal v2-build your-executable
```

You are now ready to explore gi-gtk4-declarative! To find inspiration,
check out the [full runnable examples in the
repository](https://github.com/owickstrom/gi-gtk-declarative/blob/master/examples/),
or [dive right into the documentation](widgets/the-widget-type.md).
