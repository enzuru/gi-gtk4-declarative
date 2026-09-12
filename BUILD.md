# Build Instructions

## With Nix

The flake in this repository gives you GHC with the gi-gtk 4 bindings,
the GTK 4 libraries they load, and a nested X server for the tests:

```
nix develop
```

Inside that shell, the Makefile builds and tests everything:

```
make build      # typecheck the two libraries
make examples   # build the example programs
make check      # run both test suites under Xvfb
```

## With Cabal

You need GTK 4 and the GObject introspection data for it. Follow [the
gi-gtk README](https://github.com/haskell-gi/haskell-gi#installation) to
install them, then run:

```
cabal build all
```

The test suites need a display. If you do not have one, run them under
Xvfb:

```
xvfb-run cabal test all
```

## Documentation

The documentation is built with [MkDocs](https://www.mkdocs.org/).

## Examples

There are some examples in [examples/](examples/), using the
`GI.Gtk.Declarative.App.Simple` architecture, which also showcase
`GI.Gtk.Declarative` (the markup library).

To run the `examples/Hello.hs` example:

``` shell
cabal run example Hello
```

Or, inside the Nix shell:

``` shell
make examples && .build/example Hello
```
