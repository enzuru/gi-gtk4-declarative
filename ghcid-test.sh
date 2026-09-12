#!/usr/bin/env bash

# A GHCi session that runs the library's test suite as you edit it.
#
# The tests need a display. Run this under `xvfb-run` if you do not have
# one.
#
# See ghcid.sh for why the heap is capped.

export HEDGEHOG_COLOR=1

ghcid \
  -c 'ghci -igi-gtk-declarative/src -igi-gtk-declarative/test +RTS -M4g -RTS' \
  --test ':main' \
  --color=always \
  --reload=gi-gtk-declarative \
  --restart=gi-gtk-declarative/test \
  Main
