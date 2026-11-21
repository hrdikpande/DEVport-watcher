#!/bin/zsh
# UI smoke test: launches build/Ports.app next to the dev harness, checks the app stays up for 10 s,
# then reads its status-item menu through System Events and checks the harness rows and badges.
#
#   ./Scripts/ui_smoke.sh               # needs build/Ports.app (./Scripts/build_app.sh --no-install)
#   PORT_BASE=47300 ./Scripts/ui_smoke.sh
#
# Exit codes: 0 passed, 1 failed, 77 skipped (no Accessibility permission), 78 manual (rows unreadable via
# System Events); neither 77 nor 78 counts as passed.
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
# Panel open ⇔ the app has an on-screen window taller than 300 pt (the status item itself is ~24 pt).
PANEL_WINDOWS="${TMPDIR:-/tmp}/ports-panel-windows"
[[ -x "$PANEL_WINDOWS" && "$PANEL_WINDOWS" -nt Scripts/panel_windows.swift ]] || swiftc -O Scripts/panel_windows.swift -o "$PANEL_WINDOWS" 2>/dev/null
panel_open() { "$PANEL_WINDOWS" "$APP_PID" | awk '$3 > 300 { found = 1 } END { exit !found }'; }
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
# Popover elements are only reachable through raw AX attributes (System Events' `pop over 1` and
# `entire contents` fail on them), so walk AXChildren and read AXDescription / AXTitle / AXValue.
read_menu() {
  osascript <<OSA 2>/dev/null || true
on attr(el, a)
  tell application "System Events"
    try
      set v to value of attribute a of el
      if class of v is text and v is not "" then return v & linefeed
    end try
  end tell
  return ""
end attr
on walk(el, depth)
  set out to my attr(el, "AXDescription") & my attr(el, "AXTitle") & my attr(el, "AXValue")
  if depth < 16 then
    set kids to {}
    tell application "System Events"
      try
        set kids to value of attribute "AXChildren" of el
      end try
    end tell
    repeat with c in kids
      try
        set out to out & my walk(c, depth + 1)
      end try
    end repeat
  end if
  return out
end walk
tell application "System Events"
  tell (first process whose unix id is $APP_PID)
    set out to ""
    repeat with p in (value of attribute "AXChildren" of menu bar item 1 of menu bar 1)
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

# The panel must open: the status item gains exactly one AX child (the popover) after the click.
# The panel's view is built when it opens, so give it up to 10 s to appear.
for _ in {1..20}; do panel_open && break; sleep 0.5; done
panel_open || fail "the panel did not open"
echo "ui_smoke: panel opens"

# Rows can't be read: System Events lists the popover but returns nothing beneath it (3 attempts:
# entire contents, recursive UI elements, raw AXChildren walk). Row/badge checks are manual (VoiceOver).
items=$(read_menu)
if [[ -z "$items" ]]; then
  echo "ui_smoke: MANUAL: panel rows aren't readable through System Events; check them with VoiceOver"
  exit 78
fi
check_menu
if (( errors > 0 )); then
  print -n -- "$report"
  fail "$errors panel expectation(s) not met"
fi
echo "ui_smoke: PASSED (panel rows and badges as expected)"
