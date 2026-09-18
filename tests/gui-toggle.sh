#!/usr/bin/env bash
#
# Click a toggle group with real X11 input.
#
# The reason an AdwToggleGroup is in this library is a claim about GTK:
# a click cannot turn the chosen toggle off. A GtkToggleButton bound to
# the markup is broken because a click on one that is already on turns
# it off, and the markup that follows says what it said before, so
# nothing turns it back on.
#
# Nothing can synthesise a click, so this clicks the same toggle twice
# for real and reads back what the group says is chosen.
#
# Run it under a display. The Makefile runs it under Xvfb.

set -u

binary=${1:?usage: gui-toggle.sh <toggle-app-binary>}
title=gi-gtk4-declarative-toggle-test

# A nested X server has no GL worth speaking of, and without these the
# window never appears at all.
export GDK_BACKEND=x11
export GSK_RENDERER=cairo

log=$(mktemp)
trap 'rm -f "$log"' EXIT

"$binary" > "$log" 2>&1 &
app=$!

# Wait for the window, for up to ten seconds.
window=
for _ in $(seq 1 20); do
  window=$(xdotool search --name "$title" 2>/dev/null | head -1)
  [ -n "$window" ] && break
  sleep 0.5
done

fail () {
  echo "FAIL: $1"
  echo "--- what the application printed:"
  cat "$log"
  kill $app 2>/dev/null
  wait $app 2>/dev/null
  exit 1
}

[ -n "$window" ] || fail "the application never put a window on the display"

xdotool windowfocus --sync "$window" 2>/dev/null
sleep 1

# The middle of the window, which is the middle toggle whatever width
# the group takes.
xdotool mousemove --window "$window" 150 60 click 1
sleep 1

chosen=$(grep '^CHOSE ' "$log" | tail -1 | cut -d' ' -f2)
[ -n "$chosen" ] || fail "a click did not reach the toggle group"

# The same toggle again. A toggle button would turn itself off here.
xdotool mousemove --window "$window" 150 60 click 1
sleep 2

kill $app 2>/dev/null
wait $app 2>/dev/null

# What the group says after the second click, which is the last thing
# it said.
after=$(grep '^ACTIVE ' "$log" | tail -1 | cut -d' ' -f2)

[ "$after" = "$chosen" ] || fail \
  "clicking the chosen toggle left the group saying '$after' rather than '$chosen'"

grep -q '^ACTIVE none$' "$log" && fail \
  "the group had nothing chosen at some point, which is what this test is against"

echo "ok   a click chose a toggle, and clicking it again left it chosen"
