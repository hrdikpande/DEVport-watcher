#!/bin/zsh
# Performance gate: with the dev harness running, measures the warm scan (`ports list --timing`),
# then launches build/Ports.app, opens its menu 3 times and reports physical footprint and RSS.
# With --idle-cpu SECONDS it measures the app's own CPU time over three such windows with the menu closed (median).
#
#   ./Scripts/perf_check.sh
#   ./Scripts/perf_check.sh --idle-cpu 120
#   ./Scripts/perf_check.sh --idle-cpu 120 --no-harness    # idle CPU of the app alone
#
# Memory is the physical footprint (Activity Monitor's "Memory"); RSS is printed for information only.
# Leak check: the footprint after opening the panel 20× must be within 5 MB of the footprint after 3×.
# Exits non-zero if the warm scan is >= 30 ms, the footprint >= 40 MB, the leak check fails, or idle CPU >= 0.1 %.
# Only processes this script starts are signalled.
set -euo pipefail
cd "$(dirname "$0")/.."

IDLE=0 HARNESS=1
while (( $# )); do
  case $1 in
    --idle-cpu) IDLE=${2:?seconds}; shift ;;
    --no-harness) HARNESS=0 ;;
    *) echo "usage: $0 [--idle-cpu SECONDS] [--no-harness]" >&2; exit 64 ;;
  esac
  shift
done
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
# Panel open ⇔ the app has an on-screen window taller than 300 pt (the status item itself is ~24 pt).
PANEL_WINDOWS="${TMPDIR:-/tmp}/ports-panel-windows"
[[ -x "$PANEL_WINDOWS" && "$PANEL_WINDOWS" -nt Scripts/panel_windows.swift ]] || swiftc -O Scripts/panel_windows.swift -o "$PANEL_WINDOWS" 2>/dev/null
panel_open() { "$PANEL_WINDOWS" "$APP_PID" | awk '$3 > 300 { found = 1 } END { exit !found }'; }
trap cleanup EXIT
trap 'exit 130' INT TERM

if (( HARNESS )); then
  PORT_BASE=$BASE Scripts/dev_harness.sh --serve >"$LOG" 2>&1 &
  HARNESS_PID=$!
  for _ in {1..900}; do grep -q '^READY' "$LOG" && break; sleep 0.1; done
  grep -q '^READY' "$LOG" || { cat "$LOG" >&2; echo "perf_check: harness not ready" >&2; exit 1; }
fi

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
# The idle measurement needs the panel closed: click again until it is (at most 3 tries).
for _ in 1 2 3; do
  panel_open || break
  click; sleep 2
done
panel_open && { echo "perf_check: FAIL the panel didn't close"; exit 1; }
fp() { vmmap --summary "$APP_PID" 2>/dev/null | awk '/^Physical footprint:/ { v = $3; u = substr(v, length(v)); n = v + 0
  if (u == "K") n /= 1024; else if (u == "G") n *= 1024; printf "%.1f", n }'; }
footprint=$(fp)
rss=$(( $(ps -o rss= -p "$APP_PID") / 1024 ))
echo "  app: physical footprint ${footprint} MB after 3 panel opens (RSS ${rss} MB, information only)"
for _ in {4..20}; do click; sleep 2; click; sleep 1; done
for _ in 1 2 3; do panel_open || break; click; sleep 2; done
sleep 3
footprint20=$(fp)
echo "  app: physical footprint ${footprint20} MB after 20 panel opens"
cpu=""
if (( IDLE > 0 )); then
  # The app's own CPU time (user + system, `ps -o cputime=`) at the start and end of each closed-panel window;
  # idle % = CPU-time delta / window length. Three windows; the gate uses the median (see NOTES.md for why).
  secs() { ps -o cputime= -p "$APP_PID" | tr -d ' ' | awk -F: '{ t = 0; for (i = 1; i <= NF; i++) t = t * 60 + $i; printf "%.2f", t }'; }
  windows=()
  for w in 1 2 3; do
    c0=$(secs); t0=$(date +%s)
    sleep "$IDLE"
    c1=$(secs); t1=$(date +%s)
    windows+=$(awk -v a="$c0" -v b="$c1" -v s=$((t1 - t0)) 'BEGIN { printf "%.3f", (b - a) / s * 100 }')
  done
  cpu=$(print -l $windows | sort -n | sed -n 2p)
  echo "  app: idle CPU windows ${windows[1]} % · ${windows[2]} % · ${windows[3]} % (${IDLE} s each, menu closed); median ${cpu} %"
fi

fail=0
(( worst < 30 )) || { echo "perf_check: FAIL warm scan ${worst} ms >= 30 ms"; fail=1; }
awk -v a="$footprint" 'BEGIN { exit !(a < 40) }' || { echo "perf_check: FAIL footprint ${footprint} MB >= 40 MB"; fail=1; }
awk -v a="$footprint" -v b="$footprint20" 'BEGIN { exit !(b - a <= 5) }' \
  || { echo "perf_check: FAIL leak check: footprint grew from ${footprint} to ${footprint20} MB over 17 more opens"; fail=1; }
if [[ -n "$cpu" && "$cpu" != "?" ]]; then
  awk -v c="$cpu" 'BEGIN { exit !(c < 0.1) }' || { echo "perf_check: FAIL idle CPU median ${cpu} % >= 0.1 %"; fail=1; }
fi
(( fail == 0 )) && echo "perf_check: PASSED (worst warm scan ${worst} ms)"
exit $fail
