# Build Instructions

## With Nix

The flake in this repository gives you GHC with the gi-gtk 4 bindings,
the GTK 4 libraries they load, and a nested X server for the tests:

```
nix develop
```

Inside that shell, the Makefile builds and tests everything:

```
make build      # typecheck the three libraries
make examples   # build the example programs
make check      # run every test suite under Xvfb
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

Inside `nix develop`, every dependency is already in the compiler's
package database, so cabal resolves the build without a Hackage index.
Two packages there hold a module called `GI.Gtk`: `gi-gtk`, which is the
one the cabal files name, and `gi-gtk4`, a copy of it under another
name. Cabal is unaffected, because it names each package it passes to
the compiler. The Makefile hides the copy, because a call to GHC that
does not name its packages sees both.

## Running a GTK 4 program without a screen

A GTK 4 program under Xvfb needs two settings, or it starts, draws
nothing, and never puts a window on the display:

```
export GDK_BACKEND=x11
export GSK_RENDERER=cairo
```

A nested X server has no GL worth speaking of, which is what the second
one is about. The test suites set both for themselves.

## Memory

Every compile here loads the whole gi-gtk 4 interface, which is large.
The Makefile caps GHC's heap at 4 GiB with `-M4g`, so a compiler that
runs away dies with a heap overflow message instead of growing until the
kernel kills something else on the machine to make room.

Measured peaks, from a clean build:

| What | GHC heap | Total in use |
| --- | --- | --- |
| `make build` | 294 MiB | 608 MiB |
| `make check-lib` | 335 MiB | 838 MiB |
| `make examples` | 359 MiB | 974 MiB |
| `make examples`, at `-O2` | 1.2 GiB | 2.6 GiB |

Cabal calls the compiler itself, so pass the cap through the
environment:

```
GHCRTS=-M4g cabal build all
```

A GHCi session is the one to watch. It lives for hours, reloads on every
save, and holds on to more after each reload. `ghcid.sh` and
`ghcid-test.sh` cap it for that reason. If you start one yourself, cap
it too:

```
ghci -igi-gtk4-declarative/src +RTS -M4g -RTS
```

Run one compiler at a time. `make -j` multiplies the memory rather than
dividing the time, so the Makefile declares itself not parallel.

## Documentation

The documentation is built with [MkDocs](https://www.mkdocs.org/), which
has a Nix shell of its own, since it needs Python rather than GHC:

```
nix develop .#docs --command make docs
```

## Benchmark

There is a benchmark for the patching, which needs a display:

```
make bench
```

It measures rather than checks, and takes minutes rather than seconds,
so `make check` leaves it alone.

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
