#!/bin/zsh
# Performance gate: with the dev harness running, measures the warm scan (`ports list --timing`),
# then launches build/Ports.app, opens its menu 3 times and reports physical footprint and RSS.
# With --idle-cpu SECONDS it also averages the app's CPU over that many seconds with the menu closed.
#
#   ./Scripts/perf_check.sh
#   ./Scripts/perf_check.sh --idle-cpu 120
#
# Exits non-zero if the warm scan is >= 30 ms, the footprint >= 40 MB, or idle CPU >= 0.1 %.
# Only processes this script starts are signalled.
set -euo pipefail
cd "$(dirname "$0")/.."

IDLE=0
[[ "${1:-}" == "--idle-cpu" ]] && IDLE=${2:?seconds}
BASE=${PORT_BASE:-47600}
APP=build/Ports.app/Contents/MacOS/Ports
[[ -x "$APP" ]] || { echo "perf_check: build the app first (./Scripts/build_app.sh --no-install)" >&2; exit 1; }

LOG=$(mktemp -t ports-perf)
HARNESS_PID="" APP_PID=""
cleanup() {
  set +e
  [[ -n "$APP_PID" ]] && { kill -TERM "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; }
  [[ -n "$HARNESS_PID" ]] && { kill -TERM "$HARNESS_PID" 2>/dev/null; wait "$HARNESS_PID" 2>/dev/null; }
  # Forked harness workers leave within a moment of their parent; wait until the ports are free.
  for _ in {1..100}; do lsof -nP -iTCP:$BASE-$((BASE+20)) -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 0.1; done
  rm -f "$LOG"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

PORT_BASE=$BASE Scripts/dev_harness.sh --serve >"$LOG" 2>&1 &
HARNESS_PID=$!
for _ in {1..900}; do grep -q '^READY' "$LOG" && break; sleep 0.1; done
grep -q '^READY' "$LOG" || { cat "$LOG" >&2; echo "perf_check: harness not ready" >&2; exit 1; }

swift build -q -c release --product ports
CLI="$(swift build -c release --show-bin-path)/ports"
"$CLI" list --timing >/dev/null                       # warm-up
worst=0
for i in 1 2 3 4 5; do
  line=$("$CLI" list --timing | tail -n 1)
  ms=$(print -r -- "$line" | sed -E 's/^scan: ([0-9.]+) ms warm.*/\1/')
  echo "  $line"
  (( ms > worst )) && worst=$ms
done

"$APP" -filter 0 >/dev/null 2>&1 &
APP_PID=$!
sleep 6
click() {
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to click menu bar item 1 of menu bar 1" >/dev/null 2>&1 || true
}
for _ in 1 2 3; do click; sleep 3; click; sleep 2; done        # open the panel, then close it again
open_now=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to count of (value of attribute \"AXChildren\" of menu bar item 1 of menu bar 1)" 2>/dev/null || echo "?")
[[ "$open_now" == "0" ]] || echo "  note: panel may still be open ($open_now)"
footprint=$(vmmap --summary "$APP_PID" 2>/dev/null | awk '/^Physical footprint:/ { print $3 }')
rss=$(( $(ps -o rss= -p "$APP_PID") / 1024 ))
echo "  app: physical footprint $footprint, RSS ${rss} MB (menu opened 3×)"

cpu=""
if (( IDLE > 0 )); then
  # top samples once per second; the first sample has no interval, so drop it.
  cpu=$(top -l $((IDLE + 1)) -s 1 -pid "$APP_PID" -stats cpu | awk '$1 ~ /^[0-9.]+$/ { n++; if (n > 1) { s += $1; c++ } } END { if (c) printf "%.3f", s / c; else print "?" }')
  echo "  app: idle CPU ${cpu} % averaged over ${IDLE} s (menu closed)"
fi

fail=0
(( worst < 30 )) || { echo "perf_check: FAIL warm scan ${worst} ms >= 30 ms"; fail=1; }
fp_mb=$(print -r -- "$footprint" | sed -E 's/M$//')
if [[ "$footprint" == *K ]]; then fp_mb=0; elif [[ "$footprint" == *G ]]; then fp_mb=99999; fi
(( fp_mb < 40 )) || { echo "perf_check: FAIL footprint $footprint >= 40 MB"; fail=1; }
if [[ -n "$cpu" && "$cpu" != "?" ]]; then
  (( cpu < 0.1 )) || { echo "perf_check: FAIL idle CPU ${cpu} % >= 0.1 %"; fail=1; }
fi
(( fail == 0 )) && echo "perf_check: PASSED (worst warm scan ${worst} ms)"
exit $fail
