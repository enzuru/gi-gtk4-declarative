#!/usr/bin/env bash

# A GHCi session that reloads the library, app-simple, and the examples
# as you edit them.
#
# The heap cap matters here more than it does for a one-shot build. This
# session lives for hours and reloads on every save, and GHCi holds on
# to more after each reload. With -M it dies with a heap overflow when
# it gets out of hand, and ghcid starts a new one; without it, it grows
# until the kernel kills something on the machine. A fresh load of the
# gi-gtk bindings takes about 520 MiB, so 4 GiB is room to work in.

ghcid \
  -c 'ghci -igi-gtk4-declarative/src -igi-gtk4-declarative-app-simple/src -iexamples examples/Main.hs +RTS -M4g -RTS' \
  --reload=gi-gtk4-declarative \
  --reload=gi-gtk4-declarative-app-simple \
  --reload=examples
