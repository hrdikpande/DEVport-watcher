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

# Clicking a status item blocks AppleScript until the menu closes, so click without waiting,
# read the open menu in a second call, then close it with Escape.
osascript >/dev/null <<OSA
tell application "System Events"
  tell (first process whose unix id is $APP_PID)
    ignoring application responses
      click menu bar item 1 of menu bar 1
    end ignoring
  end tell
end tell
OSA
read_menu() {
  osascript <<OSA 2>/dev/null || true
tell application "System Events"
  tell (first process whose unix id is $APP_PID)
    set out to ""
    repeat with i in (menu items of menu 1 of menu bar item 1 of menu bar 1)
      set out to out & (name of i as text) & linefeed
    end repeat
    return out
  end tell
end tell
OSA
}

# expect <port> <text…>: the menu row for :port exists and contains every given text.
expect() {
  local port=$1; shift
  local row
  row=$(print -r -- "$items" | grep -E "^:$port( |$)" | head -n 1) || true
  if [[ -z "$row" ]]; then report+="  MISSING :$port\n"; errors=$((errors+1)); return; fi
  for want in "$@"; do
    [[ "$row" == *"$want"* ]] || { report+="  :$port lacks \"$want\": $row\n"; errors=$((errors+1)); }
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
  # Phase 4: the Health section and Leftovers appear in the menu.
  for want in "Health ·" "Leftovers ·" "Clean Up Leftovers…" "Copy Setup Prompt for AI"; do
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
