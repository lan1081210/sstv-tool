#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Pause / cancel on a real-time replay (the same two actions the window's buttons
# and space / X drive, triggered here by SIGUSR1 / SIGUSR2).
#
#   1. pause for 5 s mid-picture -> the picture carries on and completes 240/240
#   2. pause for 12 s, then cancel -> the picture ends early as "aborted", saved
#
# Takes ~90 s of wall time (it runs in real time on purpose), so it is not part
# of `make test`; run it with `make test-pause`.
set -u
cd "$(dirname "$0")/.." || exit 1
BIN=build/apricot-sstv
OUT=test/out
WAV=$OUT/Robot36.wav
fail=0

[ -x "$BIN" ] || { echo "build first: make"; exit 1; }
[ -f "$WAV" ] || "$BIN" --help >/dev/null 2>&1

echo "== 1: pause 5 s, expect the picture to continue"
rm -f "$OUT"/pz-*.png
"$BIN" --simulate "$WAV" --no-view --prefix pz --out "$OUT" > /tmp/pause1.log 2>&1 &
PID=$!
sleep 8;  kill -USR1 $PID; echo "   pause  @8 s"
sleep 5;  kill -USR1 $PID; echo "   resume @13 s"
sleep 34; kill $PID 2>/dev/null; wait $PID 2>/dev/null
if grep -q 'image ended (complete): Robot 36, 240/240' /tmp/pause1.log; then
    echo "   PASS  picture completed 240/240 after the pause"
else
    echo "   FAIL  $(grep 'image ended' /tmp/pause1.log | head -2)"
    fail=$((fail+1))
fi

echo "== 2: pause, then cancel, expect an aborted picture on disk"
rm -f "$OUT"/pc-*.png
"$BIN" --simulate "$WAV" --no-view --prefix pc --out "$OUT" > /tmp/pause2.log 2>&1 &
PID=$!
sleep 8;  kill -USR1 $PID; echo "   pause  @8 s"
sleep 3;  kill -USR1 $PID; echo "   resume @11 s"
sleep 6;  kill -USR2 $PID; echo "   cancel @17 s"
sleep 4;  kill $PID 2>/dev/null; wait $PID 2>/dev/null
if grep -q 'image ended (aborted)' /tmp/pause2.log && ls "$OUT"/pc-*.png >/dev/null 2>&1; then
    echo "   PASS  $(grep 'image ended (aborted)' /tmp/pause2.log | sed 's/^ *//') -> $(ls "$OUT"/pc-*.png | xargs -n1 basename | tr '\n' ' ')"
else
    echo "   FAIL  $(grep -E 'image ended|started' /tmp/pause2.log | tr '\n' '|')"
    fail=$((fail+1))
fi

echo
[ "$fail" -eq 0 ] && echo "pause/cancel: 2 passed" || echo "pause/cancel: $fail failed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
