#!/bin/zsh
# UI smoke test: launches build/Ports.app next to the dev harness, checks the app stays up for 10 s,
# then reads its status-item menu through System Events and checks the harness rows and badges.
#
#   ./Scripts/ui_smoke.sh               # needs build/Ports.app (./Scripts/build_app.sh --no-install)
#   PORT_BASE=47300 ./Scripts/ui_smoke.sh
#
# Exit codes: 0 passed, 1 failed, 77 skipped (no Accessibility permission; never counts as passed).
# Only processes this script starts are ever signalled (this app instance and the harness).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Ports.app
BASE=${PORT_BASE:-47300}
[[ -x "$APP/Contents/MacOS/Ports" ]] || { echo "ui_smoke: $APP missing; run ./Scripts/build_app.sh --no-install" >&2; exit 1; }

LOG=$(mktemp -t ports-ui-smoke)
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

fail() { echo "ui_smoke: FAIL: $*" >&2; exit 1; }

ax_enabled=$(osascript -e 'tell application "System Events" to get UI elements enabled' 2>/dev/null || echo false)
if [[ "$ax_enabled" != "true" ]]; then
  echo "ui_smoke: SKIPPED: no Accessibility permission for this terminal (System Settings › Privacy & Security › Accessibility)."
  exit 77
fi

PORT_BASE=$BASE Scripts/dev_harness.sh --serve >"$LOG" 2>&1 &
HARNESS_PID=$!
for _ in {1..900}; do
  grep -q '^READY' "$LOG" 2>/dev/null && break
  kill -0 "$HARNESS_PID" 2>/dev/null || { cat "$LOG" >&2; fail "harness exited early"; }
  sleep 0.1
done
grep -q '^READY' "$LOG" || fail "harness not ready after 90 s"

# -filter 0: argument-domain default, so the Developer view shows whatever the saved preference is.
"$APP/Contents/MacOS/Ports" -filter 0 >/dev/null 2>&1 &
APP_PID=$!
sleep 10
kill -0 "$APP_PID" 2>/dev/null || fail "app exited within 10 s"
echo "ui_smoke: app alive after 10 s (pid $APP_PID)"

# Open the panel (a popover) by clicking the status item, then read every accessibility element's text.
osascript >/dev/null <<OSA
tell application "System Events"
  tell (first process whose unix id is $APP_PID)
    click menu bar item 1 of menu bar 1
  end tell
end tell
OSA
read_menu() {
  osascript <<OSA 2>/dev/null || true
on walk(el, depth)
  set out to ""
  tell application "System Events"
    try
      set d to description of el
      if d is not missing value and d is not "" then set out to out & d & linefeed
    end try
    try
      set n to name of el
      if n is not missing value and n is not "" then set out to out & n & linefeed
    end try
    try
      set v to value of el
      if class of v is text and v is not "" then set out to out & v & linefeed
    end try
    if depth < 14 then
      set kids to {}
      try
        set kids to UI elements of el
      end try
      repeat with c in kids
        try
          set out to out & my walk(c, depth + 1)
        end try
      end repeat
    end if
  end tell
  return out
end walk
tell application "System Events"
  tell (first process whose unix id is $APP_PID)
    set out to ""
    repeat with p in (UI elements of menu bar item 1 of menu bar 1)
      set out to out & my walk(p, 0)
    end repeat
    return out
  end tell
end tell
OSA
}

# expect <port> <text…>: the row for :port (its VoiceOver label "Port N, …") exists and contains every text.
expect() {
  local port=$1; shift
  local row
  row=$(print -r -- "$items" | grep -E "^Port $port," | head -n 1) || true
  if [[ -z "$row" ]]; then report+="  MISSING :$port\n"; errors=$((errors+1)); return; fi
  for want in "$@"; do
    if [[ "$want" == !* ]]; then
      [[ "$row" != *"${want#!}"* ]] || { report+="  :$port has \"${want#!}\": $row\n"; errors=$((errors+1)); }
    else
      [[ "$row" == *"$want"* ]] || { report+="  :$port lacks \"$want\": $row\n"; errors=$((errors+1)); }
    fi
  done
}

check_menu() {
  errors=0 report=""
  # Harness rows (see Scripts/dev_harness.sh for the scenario on each port).
  expect $((BASE+0)) "python"
  expect $((BASE+1)) "LAN"
  expect $((BASE+4)) "python"
  expect $((BASE+5)) "STOPPED"
  expect $((BASE+6)) "Redis"
  expect $((BASE+9)) "harness-web" "feature/demo"
  expect $((BASE+10)) "×3"
  expect $((BASE+13)) "Vite"
  expect $((BASE+14)) "ORPHAN"
  expect $((BASE+15)) "TWICE"
  expect $((BASE+6)) "DB"
  expect $((BASE+18)) "DB"
  expect $((BASE+19)) "DB" "NETWORK"
  expect $((BASE+23)) "Harness & Page"
  expect $((BASE+24)) "JSON"
  expect $((BASE+20)) "TUNNEL"
  expect $((BASE+0)) "PUBLIC" "!NEW"
  # Panel sections, Leftovers, footer and the filter chips (Phase 10).
  for want in "Health" "Leftovers" "Clean Up…" "Check Port…" "Find Free Port…" "Copy Setup Prompt for AI" "Developer" "Tunnels" "Settings"; do
    print -r -- "$items" | grep -qF "$want" || { report+="  menu lacks \"$want\"\n"; errors=$((errors+1)); }
  done
}

# The menu opens from cache and fills in as the open-menu scan lands: re-read until it matches (30 s cap).
items="" errors=1
for _ in {1..30}; do
  sleep 1
  items=$(read_menu)
  [[ -n "$items" ]] || continue
  check_menu
  (( errors == 0 )) && break
done
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
[[ -n "$items" ]] || fail "could not read the status-item menu"
if (( errors > 0 )); then
  print -n -- "$report"
  echo "Menu as read:"; print -r -- "$items"
  fail "$errors menu expectation(s) not met"
fi
echo "ui_smoke: PASSED (menu rows and badges as expected)"
