#!/usr/bin/env bash
#
# Drive the input test application with real X11 input.
#
# GTK 4 reports keys and clicks through event controllers, and nothing
# can make one of those happen from code, so this is the only way to
# test that path: press a key and click a button for real, and read
# back what the application says it received.
#
# Run it under a display. The Makefile runs it under Xvfb.

set -u

binary=${1:?usage: gui-input.sh <input-test-binary>}
title=gi-gtk4-declarative-input-test

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
# 'a' is keyval 97.
xdotool key a
sleep 1
xdotool mousemove --window "$window" 150 100 click 1
sleep 1
# A double click, which counts as a second press only if the gesture
# lives through the patch the first press causes.
xdotool click --repeat 2 --delay 100 1
sleep 1

kill $app 2>/dev/null
wait $app 2>/dev/null

grep -q '^KEY 97$' "$log" || fail "a key press did not reach the key controller"
grep -q '^CLICK 1 150 100$' "$log" || fail "a click did not reach the click gesture"
grep -q '^CLICK 2 150 100$' "$log" || fail "a double click arrived as two first clicks, so the gesture did not live through the patch between them"

echo "ok   a key press, a click, and a double click reached their event controllers"
