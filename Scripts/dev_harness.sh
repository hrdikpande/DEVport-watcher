#!/bin/zsh
# Dev harness: starts throwaway listeners that exercise each Phase 1 fix, prints `ports list`,
# then waits so you can check the menu bar app by hand. Ctrl-C stops and cleans up everything.
#
#   ./Scripts/dev_harness.sh            # start scenarios, wait for Ctrl-C
#   ./Scripts/dev_harness.sh --check    # start, print the table, clean up, exit
#   PORT_BASE=48000 ./Scripts/dev_harness.sh
#
# Everything runs from a temp dir with python3 only; nothing outside it is touched.
set -euo pipefail
cd "$(dirname "$0")/.."

BASE=${PORT_BASE:-47100}
LAST=$((BASE+8))

# Refuse to start if any harness port is taken (an old harness run, or something of yours).
if busy=$(lsof -nP -iTCP:$BASE-$LAST -sTCP:LISTEN 2>/dev/null | tail -n +2) && [[ -n "$busy" ]]; then
  echo "dev_harness: ports $BASE–$LAST must be free, but these are listening:" >&2
  echo "$busy" >&2
  echo "Stop them (or use PORT_BASE=<other> $0) and try again." >&2
  exit 1
fi

WORK=$(mktemp -d -t ports-harness)
typeset -a PIDS
# Only our own children: SIGCONT (a suspended one can't die cleanly otherwise), then SIGKILL, so even
# the TERM-ignoring fake data store never survives. "No such process" is expected and ignored.
cleanup() {
  set +e
  for p in $PIDS; do kill -CONT $p 2>/dev/null; kill -KILL $p 2>/dev/null; done
  for p in $PIDS; do wait $p 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }

cat > "$WORK/serve.py" <<'PY'
import http.server, socket, ssl, sys
mode, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
family = socket.AF_INET6 if ":" in host else socket.AF_INET
if mode == "raw":                       # speaks, but not HTTP
    s = socket.socket(family)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, port)); s.listen()
    while True:
        c, _ = s.accept(); c.sendall(b"-ERR not http\r\n"); c.close()
class Server(http.server.ThreadingHTTPServer):
    address_family = family
    allow_reuse_address = True
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
srv = Server((host, port), Quiet)
if mode == "https":
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(sys.argv[4], sys.argv[5])
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY

# Folder-name trap: a python app inside a directory called "astro-dashboard" (must stay Backend).
mkdir -p "$WORK/astro-dashboard"
cp "$WORK/serve.py" "$WORK/astro-dashboard/app.py"

openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=localhost -days 1 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1

LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)

start() {   # start <port> <expectation> <command…>
  local port=$1 what=$2; shift 2
  "$@" >>"$WORK/log" 2>&1 &
  PIDS+=$!
  printf '  :%-6s %s\n' "$port" "$what"
}

echo "Scenarios (temp dir removed on exit):"
start $((BASE+0)) "loopback HTTP: Local only (127.0.0.1 / ::1), Open in Browser http" \
  python3 "$WORK/serve.py" http 127.0.0.1 $((BASE+0))
start $((BASE+1)) "all interfaces: LAN badge, 0.0.0.0 / ::" \
  python3 "$WORK/serve.py" http 0.0.0.0 $((BASE+1))
if [[ -n "$LAN_IP" ]]; then
  start $((BASE+2)) "specific LAN bind: LAN badge, shows $LAN_IP" \
    python3 "$WORK/serve.py" http "$LAN_IP" $((BASE+2))
fi
start $((BASE+3)) "TLS server: Open in Browser uses https" \
  python3 "$WORK/serve.py" https 127.0.0.1 $((BASE+3)) "$WORK/cert.pem" "$WORK/key.pem"
start $((BASE+4)) "python in ./astro-dashboard: Backend python, NOT Frontend astro" \
  python3 "$WORK/astro-dashboard/app.py" http 127.0.0.1 $((BASE+4))
start $((BASE+5)) "suspended (SIGSTOP): STOPPED badge; Kill resumes then stops it" \
  python3 "$WORK/serve.py" http 127.0.0.1 $((BASE+5))
STOPPED_PID=$PIDS[-1]
# /usr/bin/nc is a real binary (the python3 shim would re-exec and lose the fake argv[0]).
start $((BASE+6)) "fake data store ignoring SIGTERM: Databases, warning, 15 s grace, then separate Force Quit" \
  zsh -c "trap '' TERM; exec -a redis-server /usr/bin/nc -lk 127.0.0.1 $((BASE+6))"
start $((BASE+7)) "two owners (127.0.0.1 + ::1): Kill by Port lists both" \
  python3 "$WORK/serve.py" http 127.0.0.1 $((BASE+7))
start $((BASE+7)) "  (second owner)" \
  python3 "$WORK/serve.py" http ::1 $((BASE+7))
start $((BASE+8)) "non-HTTP listener: no Open in Browser" \
  python3 "$WORK/serve.py" raw 127.0.0.1 $((BASE+8))

sleep 1.5
kill -STOP "$STOPPED_PID"

echo "\nports list (harness ports only):"
swift run -q ports list | awk -v lo=$BASE -v hi=$((BASE+8)) '{ p = substr($1, 2) + 0 } p >= lo && p <= hi'

echo "\nAfter any stop, the app should report \"Port N is free\" or \"Still listening: …\"."
echo "On this Mac, ControlCenter on :5000/:7000 (AirPlay Receiver) shows in the Developer view with an explanation."

if [[ "${1:-}" == "--check" ]]; then exit 0; fi
echo "\nOpen the Ports menu to check each row. Ctrl-C to stop the harness."
while true; do sleep 3600 & wait $!; done      # wait is interruptible, so the trap runs at once
