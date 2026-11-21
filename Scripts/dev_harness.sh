#!/bin/zsh
# Dev harness: starts throwaway listeners that exercise each phase's scenarios, prints `ports list`,
# then waits so you can check the menu bar app by hand. Ctrl-C stops and cleans up everything.
#
#   ./Scripts/dev_harness.sh            # start scenarios, print the table, wait for Ctrl-C
#   ./Scripts/dev_harness.sh --serve    # same, quieter; prints READY when every scenario listens (ui_smoke.sh)
#   ./Scripts/dev_harness.sh --check    # start, assert every row of `ports list`, clean up, verify no
#                                       # listener is left; exits non-zero on any mismatch
#   PORT_BASE=48000 ./Scripts/dev_harness.sh
#   ./Scripts/dev_harness.sh --with-launchd --check   # owner-run only: adds a temporary LaunchAgent
#                                       # (temp-dir plist, label io.github.hrdikpande.ports.harness.<random>,
#                                       # bootstrap/bootout gui/$UID); refused when CI is set
#
# Everything runs from a temp dir with python3 only; only processes this script starts are signalled.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="" WITH_LAUNCHD=0
for arg in "$@"; do
  case $arg in
    --with-launchd) WITH_LAUNCHD=1 ;;
    --serve|--check) MODE=$arg ;;
    *) echo "usage: $0 [--serve|--check] [--with-launchd]" >&2; exit 64 ;;
  esac
done
# --with-launchd (owner-run only, never on CI): adds a temporary LaunchAgent that must never be flagged.
if (( WITH_LAUNCHD )) && [[ -n "${CI:-}" ]]; then echo "dev_harness: --with-launchd never runs when CI is set" >&2; exit 64; fi
LAUNCHD_PREFIX="io.github.hrdikpande.ports.harness."
LABEL=""
BASE=${PORT_BASE:-47100}
LAST=$((BASE + 24))

listening() { lsof -nP -iTCP:$BASE-$LAST -sTCP:LISTEN 2>/dev/null | tail -n +2; }

# Refuse to start if any harness port is taken (an old harness run, or something of yours).
if busy=$(listening) && [[ -n "$busy" ]]; then
  echo "dev_harness: ports $BASE–$LAST must be free, but these are listening:" >&2
  echo "$busy" >&2
  echo "Stop them (or use PORT_BASE=<other> $0) and try again." >&2
  exit 1
fi

command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }
swift build -q --product ports
PORTS="$(swift build --show-bin-path)/ports"

WORK=$(mktemp -d -t ports-harness)
typeset -a PIDS
# Only our own children: SIGCONT (a suspended one can't die cleanly otherwise), then SIGKILL, so even
# the TERM-ignoring fake data store never survives. Forked workers exit by themselves once their parent
# is gone. "No such process" is expected and ignored.
cleanup() {
  set +e
  [[ -n "$LABEL" ]] && launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
  # Orphans this harness created on purpose: their PIDs were written when they started.
  for f in "$WORK"/*.pid(N); do PIDS+=$(<"$f"); done
  for p in $PIDS; do kill -CONT $p 2>/dev/null; kill -KILL $p 2>/dev/null; done
  for p in $PIDS; do wait $p 2>/dev/null; done
  [[ -n "${ENGINE_SOCK:-}" && -S "$ENGINE_SOCK" ]] && rm -f -- "$ENGINE_SOCK"
  PIDS=()
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

cat > "$WORK/serve.py" <<'PY'
import http.server, os, socket, ssl, sys, time
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
# Fixed reply, no filesystem access: some scenarios listen on the LAN, so never serve files.
# Phase 9: "title" and "json" modes answer GET with a fixed page / fixed JSON (still no filesystem access).
FIXED = {"title": ("text/html", b"<html><head><title>Harness &amp; Page</title></head><body>hi</body></html>"),
         "json": ("application/json", b'{"ok": true}')}
class Quiet(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
    def do_GET(self):
        if mode not in FIXED: return self.do_HEAD()
        ctype, body = FIXED[mode]
        self.send_response(200); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = Server((host, port), Quiet)
if mode == "prefork":                   # master + 2 forked workers sharing the listening socket
    master = os.getpid()
    for _ in range(2):
        if os.fork() == 0:
            while os.getppid() == master: time.sleep(0.2)   # leave as soon as the master is gone
            os._exit(0)
if mode in FIXED: pass
if mode == "https":
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(sys.argv[4], sys.argv[5])
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY

# Folder-name trap: a python app inside a directory called "astro-dashboard" (must stay Backend).
mkdir -p "$WORK/astro-dashboard"
cp "$WORK/serve.py" "$WORK/astro-dashboard/app.py"

# Synthetic projects (Phase 2): a git repo on a branch, a worktree of it, and a monorepo package.
mkdir -p "$WORK/harness-web/.git/worktrees/wt" "$WORK/harness-wt" "$WORK/harness-mono/.git" "$WORK/harness-mono/apps/api"
echo '{"name": "harness-web"}' > "$WORK/harness-web/package.json"
echo 'ref: refs/heads/feature/demo' > "$WORK/harness-web/.git/HEAD"
echo 'ref: refs/heads/wt-branch' > "$WORK/harness-web/.git/worktrees/wt/HEAD"
echo 'gitdir: ../harness-web/.git/worktrees/wt' > "$WORK/harness-wt/.git"
echo '{"name": "harness-wt"}' > "$WORK/harness-wt/package.json"
echo '{"name": "harness-mono", "workspaces": ["apps/*"]}' > "$WORK/harness-mono/package.json"
echo 'ref: refs/heads/main' > "$WORK/harness-mono/.git/HEAD"
echo '{"name": "api"}' > "$WORK/harness-mono/apps/api/package.json"
for d in harness-web harness-wt harness-mono/apps/api; do cp "$WORK/serve.py" "$WORK/$d/app.py"; done

openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=localhost -days 1 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1

cd "$WORK"     # scenarios run outside any real project, so labels come only from the synthetic ones
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
typeset -a EXPECT_PORTS

say() { [[ "$MODE" == "--serve" ]] || print -r -- "$@"; }
start() {   # start <port> <expectation> <command…>
  local port=$1 what=$2; shift 2
  "$@" >>"$WORK/log" 2>&1 &
  PIDS+=$!
  EXPECT_PORTS+=$port
  say "$(printf '  :%-6s %s' "$port" "$what")"
}
start_in() {  # start_in <dir> <port> <expectation> <command…>: same, with <dir> as working directory
  local dir=$1; shift
  local port=$1 what=$2; shift 2
  (cd "$dir" && exec "$@") >>"$WORK/log" 2>&1 &
  PIDS+=$!
  EXPECT_PORTS+=$port
  say "$(printf '  :%-6s %s' "$port" "$what")"
}

say "Scenarios (temp dir removed on exit):"
start $((BASE+0)) "loopback HTTP: Local only (127.0.0.1 / ::1), Open in Browser http" \
  python3 "$WORK/serve.py" http 127.0.0.1 $((BASE+0))
start $((BASE+1)) "all interfaces: LAN badge, 0.0.0.0 / ::" \
  python3 "$WORK/serve.py" http 0.0.0.0 $((BASE+1))
if [[ -n "$LAN_IP" ]]; then
  start $((BASE+2)) "specific LAN bind: LAN badge, shows the LAN address" \
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
start_in "$WORK/harness-web" $((BASE+9)) "project + branch: python3 · harness-web · feature/demo" \
  python3 app.py http 127.0.0.1 $((BASE+9))
start $((BASE+10)) "master + 2 forked workers: one row, ×3 workers" \
  python3 "$WORK/serve.py" prefork 127.0.0.1 $((BASE+10))
start_in "$WORK/harness-wt" $((BASE+11)) "git worktree: harness-wt · wt-branch" \
  python3 app.py http 127.0.0.1 $((BASE+11))
start_in "$WORK/harness-mono/apps/api" $((BASE+12)) "monorepo package: harness-mono › api · main" \
  python3 app.py http 127.0.0.1 $((BASE+12))

# Phase 3: the framework table names a dev server by its argv[0] (nc stands in for vite; no files are served).
start $((BASE+13)) "framework table: Frontend, Vite" \
  zsh -c "exec -a vite /usr/bin/nc -lk 127.0.0.1 $((BASE+13))"

# Phase 4: a confirmed orphan (the subshell that launched it exits; it has no terminal), a second
# instance of harness-web (duplicate), and an orphaned `tsc -w` watcher without a port (Leftovers).
# Their PIDs go to *.pid files so cleanup still reaches them after they are reparented.
orphan() {  # orphan <name> <argv…>: new session (no terminal) + exec, from a subshell that exits at once
  local name=$1; shift
  zsh -c 'python3 -c "import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[2:])" "$@" >/dev/null 2>&1 & echo $! > "'"$WORK/$name.pid"'"' orphan "$@"
}
orphan orphan "$(command -v python3)" python3 "$WORK/serve.py" http 127.0.0.1 $((BASE+14))
EXPECT_PORTS+=$((BASE+14))
say "$(printf '  :%-6s %s' $((BASE+14)) "orphan (parent exited, no terminal): ORPHAN")"
start_in "$WORK/harness-web" $((BASE+15)) "second harness-web instance: TWICE here and on :$((BASE+9))" \
  python3 app.py http 127.0.0.1 $((BASE+15))
# A script named tsc, run like `node node_modules/.bin/tsc -w` (the tool is named by its script).
print 'import time\ntime.sleep(600)' > "$WORK/tsc"
orphan tsc "$(command -v python3)" python3 "$WORK/tsc" -w
say "  (no port) orphaned tsc -w: listed under Leftovers"

if (( WITH_LAUNCHD )); then
  # Leftovers of an earlier run that died before booting out its agent: only our own prefix.
  for old in $(launchctl list | awk -v p="$LAUNCHD_PREFIX" 'index($3, p) == 1 { print $3 }'); do
    launchctl bootout "gui/$UID/$old" 2>/dev/null || true
  done
  LABEL="$LAUNCHD_PREFIX$(openssl rand -hex 4)"
  # The plist lives in the temp dir (never ~/Library/LaunchAgents), so nothing persists past bootout or logout.
  cat > "$WORK/agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$(command -v python3)</string><string>$WORK/serve.py</string>
    <string>http</string><string>127.0.0.1</string><string>$((BASE+16))</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
  launchctl bootstrap "gui/$UID" "$WORK/agent.plist"
  EXPECT_PORTS+=$((BASE+16))
  say "$(printf '  :%-6s %s' $((BASE+16)) "LaunchAgent $LABEL (temporary, fixed reply): never ORPHAN")"
fi

# Phase 6: a fake Engine API on a unix socket (fixed JSON reply, never files) and a port proxy named gvproxy
# (a copy of nc). With DOCKER_HOST pointing at the fake engine, the row must carry the container's details.
cat > "$WORK/engine.py" <<PY
import json, socket, sys
path = sys.argv[1]
body = json.dumps([{"Id": "e" * 64, "Names": ["/harness-db"], "Image": "postgres:16", "State": "running",
                    "Status": "Up 1 minute (healthy)",
                    "Ports": [{"IP": "0.0.0.0", "PrivatePort": 5432, "PublicPort": $((BASE+17)), "Type": "tcp"}],
                    "Labels": {"com.docker.compose.project": "harness", "com.docker.compose.service": "db"}}]).encode()
reply = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s" % (len(body), body)
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen()
while True:
    c, _ = s.accept(); c.recv(4096); c.sendall(reply); c.close()
PY
# Short path: unix socket names are limited to 104 bytes. The socket file is created by engine.py.
ENGINE_SOCK="/tmp/ports-harness-$$.sock"
# A stand-in listener (a copied Apple binary is killed at launch): listens on 127.0.0.1:$HARNESS_PORT, accepts,
# sends nothing, ignores its arguments, so `exec -a` can give it any argv (ssh, kubectl). Copied as gvproxy.
cat > "$WORK/listener.c" <<'C'
#include <arpa/inet.h>
#include <stdlib.h>
#include <unistd.h>
int main(void) {
  const char *p = getenv("HARNESS_PORT");
  int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(p ? atoi(p) : 0) };
  inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
  if (!p || bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 8)) return 1;
  for (;;) { int c = accept(s, 0, 0); if (c >= 0) close(c); }
}
C
cc -O -o "$WORK/listener" "$WORK/listener.c"
cp "$WORK/listener" "$WORK/gvproxy"
start $((BASE+17)) "container behind a port proxy: harness-db · postgres:16 · harness/db" \
  env HARNESS_PORT=$((BASE+17)) "$WORK/gvproxy"

# Phase 8: an ssh -L forward and a kubectl port-forward (the stand-in listener with their argv), and an ngrok
# agent whose local API (a fixed JSON reply) says it forwards :$BASE to a public URL.
start $((BASE+20)) "ssh -L forward: Tunnels, Forward → db.internal:5432 via bastion.example" \
  env HARNESS_PORT=$((BASE+20)) zsh -c "exec -a ssh '$WORK/listener' -N -L $((BASE+20)):db.internal:5432 bastion.example"
start $((BASE+21)) "kubectl port-forward: k8s · svc/web $((BASE+21))→80" \
  env HARNESS_PORT=$((BASE+21)) zsh -c "exec -a kubectl '$WORK/listener' port-forward -n shop svc/web $((BASE+21)):80"
cat > "$WORK/ngrok" <<PY
import json, socket
body = json.dumps({"tunnels": [{"public_url": "https://harness.ngrok.example", "proto": "https",
                                "config": {"addr": "http://localhost:$BASE"}}]}).encode()
reply = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s" % (len(body), body)
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", $((BASE+22)))); s.listen()
while True:
    c, _ = s.accept(); c.recv(4096); c.sendall(reply); c.close()
PY
start $((BASE+22)) "ngrok agent API: public URL shown on :$BASE (with --probe)" python3 "$WORK/ngrok"
python3 "$WORK/engine.py" "$ENGINE_SOCK" >>"$WORK/log" 2>&1 &
PIDS+=$!
for _ in {1..100}; do [[ -S "$ENGINE_SOCK" ]] && break; sleep 0.1; done

# Phase 7: an unknown server that answers PostgreSQL's SSLRequest with "N" (found only by the read-only
# handshake, which runs with --probe or while the menu is open), and a fake postgres on all interfaces.
cat > "$WORK/pgish.py" <<'PY'
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen()
while True:
    c, _ = s.accept(); c.recv(64); c.sendall(b"N"); c.close()
PY
start $((BASE+18)) "unknown server answering the PostgreSQL handshake: DB:postgres (with --probe)" \
  python3 "$WORK/pgish.py" $((BASE+18))
start $((BASE+19)) "postgres on all interfaces: DB:postgres NETWORK" \
  zsh -c "exec -a postgres /usr/bin/nc -lk 0.0.0.0 $((BASE+19))"

# Phase 9: a page with a <title> and a JSON API (fixed replies), for status · time · title and the JSON badge.
start $((BASE+23)) "HTML page: 200 · N ms · Harness & Page" python3 "$WORK/serve.py" title 127.0.0.1 $((BASE+23))
start $((BASE+24)) "JSON API: JSON badge" python3 "$WORK/serve.py" json 127.0.0.1 $((BASE+24))

# Wait until every scenario port listens (no fixed sleep), then suspend the Ctrl-Z scenario.
want=${#${(u)EXPECT_PORTS}}
up=0
for _ in {1..300}; do
  up=$(listening | awk '{ n = split($9, a, ":"); print a[n] }' | sort -u | wc -l | tr -d ' ')
  (( up >= want )) && break
  sleep 0.1
done
(( up >= want )) || { echo "dev_harness: only $up of $want scenario ports came up" >&2; cat "$WORK/log" >&2; exit 1; }
kill -STOP "$STOPPED_PID"

FULL=$(DOCKER_HOST="unix://$ENGINE_SOCK" "$PORTS" list --probe)
TABLE=$(print -r -- "$FULL" | awk -v lo=$BASE -v hi=$LAST '/^:/ { p = substr($1, 2) + 0 } /^:/ && p >= lo && p <= hi')

if [[ "$MODE" == "--check" ]]; then
  errors=0
  # expect <port> <text…>: the row for :port contains every text; "!text" must be absent.
  expect() {
    local port=$1; shift
    local row
    row=$(print -r -- "$TABLE" | grep -E "^:$port " | head -n 1) || true
    if [[ -z "$row" ]]; then echo "  FAIL :$port missing"; errors=$((errors+1)); return; fi
    for w in "$@"; do
      if [[ "$w" == !* ]]; then
        [[ "$row" != *"${w#!}"* ]] || { echo "  FAIL :$port has \"${w#!}\": $row"; errors=$((errors+1)); }
      else
        [[ "$row" == *"$w"* ]] || { echo "  FAIL :$port lacks \"$w\": $row"; errors=$((errors+1)); }
      fi
    done
  }
  rows() {    # rows <port> <n>: exactly n rows for :port
    local n
    n=$(print -r -- "$TABLE" | grep -cE "^:$1 ") || true
    (( n == $2 )) || { echo "  FAIL :$1 has $n rows, expected $2"; errors=$((errors+1)); }
  }
  expect $((BASE+0)) "Backend" "python" "!LAN"
  expect $((BASE+1)) "LAN"
  if [[ -n "$LAN_IP" ]]; then expect $((BASE+2)) "LAN"; fi
  expect $((BASE+3)) "python"
  expect $((BASE+4)) "Backend" "python" "!astro" "!python ·"
  expect $((BASE+5)) "STOPPED"
  expect $((BASE+6)) "Databases" "Redis"
  rows $((BASE+7)) 2
  expect $((BASE+8)) "python"
  expect $((BASE+9)) "python · harness-web · feature/demo"
  expect $((BASE+10)) "×3 workers"
  rows $((BASE+10)) 1
  expect $((BASE+11)) "harness-wt · wt-branch"
  expect $((BASE+12)) "harness-mono › api · main"
  expect $((BASE+13)) "Frontend" "Vite"
  expect $((BASE+14)) "ORPHAN" "!ORPHAN?" "!TWICE"
  expect $((BASE+9)) "TWICE" "!ORPHAN"
  expect $((BASE+15)) "TWICE" "!ORPHAN"
  expect $((BASE+17)) "Containers" "harness-db · postgres:16 · harness/db · healthy" "DB:postgres"
  expect $((BASE+18)) "DB:postgres" "!NETWORK"
  expect $((BASE+19)) "Databases" "DB:postgres" "NETWORK"
  expect $((BASE+6)) "DB:redis"
  expect $((BASE+0)) "!DB:" "EXPOSED ngrok → https://harness.ngrok.example"
  expect $((BASE+20)) "Tunnels" "Forward → db.internal:5432 via bastion.example"
  expect $((BASE+21)) "Tunnels" "k8s · shop/svc/web $((BASE+21))→80"
  expect $((BASE+22)) "Tunnels" "ngrok agent" "PUBLIC https://harness.ngrok.example"
  expect $((BASE+23)) "200 · " " ms · Harness & Page" "!JSON"
  expect $((BASE+24)) "200 · " "JSON"
  expect $((BASE+3)) "HTTPS" "200"
  if (( WITH_LAUNCHD )); then expect $((BASE+16)) "!ORPHAN"; fi
  # Phase 5: the bind probe agrees with the table, and next-free skips taken ports.
  "$PORTS" preflight $((BASE+0)) >/dev/null && { echo "  FAIL preflight :$((BASE+0)) said free"; errors=$((errors+1)); }
  free=$("$PORTS" next-free --from $((BASE+0))) || free=""
  [[ -n "$free" ]] && (( free > BASE + 1 )) && ! print -r -- "$TABLE" | grep -qE "^:$free " \
    || { echo "  FAIL next-free --from $((BASE+0)) gave '$free'"; errors=$((errors+1)); }
  for b in 0 1 3 4 6 8 10 11 12 13; do expect $((BASE+b)) "!ORPHAN"; done
  tsc_pid=$(<"$WORK/tsc.pid")
  print -r -- "$FULL" | grep -qE "^  PID $tsc_pid  tsc  ORPHAN" \
    || { echo "  FAIL orphaned tsc (PID $tsc_pid) missing from Leftovers"; errors=$((errors+1)); }
  # Known-port explainer: shown under ControlCenter whenever AirPlay Receiver holds 5000/7000 on this Mac.
  if print -r -- "$FULL" | grep -qE '^:(5000|7000) .*ControlCenter'; then
    print -r -- "$FULL" | grep -q '↳ AirPlay Receiver (ControlCenter) uses port' \
      || { echo "  FAIL AirPlay explainer missing under ControlCenter"; errors=$((errors+1)); }
  else
    echo "  (AirPlay Receiver is off on this Mac: explainer check skipped)"
  fi
  # Phase 11: --json parses, exit codes, a CLI stop of a harness listener, and the MCP server over stdio.
  # PORTS_SUPPORT_DIR keeps the user's real settings and history untouched.
  export PORTS_SUPPORT_DIR="$WORK/support"
  mkdir -p "$PORTS_SUPPORT_DIR"
  "$PORTS" list --json --range $BASE-$LAST | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["schemaVersion"] == 1 and len(d["ports"]) >= 10' \
    || { echo "  FAIL list --json"; errors=$((errors+1)); }
rc=0;   "$PORTS" stop $((BASE+8)) >/dev/null 2>&1 </dev/null || rc=$?
  (( rc == 3 )) || { echo "  FAIL stop without --yes exited $rc, expected 3"; errors=$((errors+1)); }
rc=0;   "$PORTS" stop --yes $((BASE+8)) >/dev/null 2>&1 || rc=$?
  (( rc == 0 )) || { echo "  FAIL stop --yes :$((BASE+8)) exited $rc"; errors=$((errors+1)); }
  "$PORTS" preflight $((BASE+8)) >/dev/null || { echo "  FAIL :$((BASE+8)) still busy after stop"; errors=$((errors+1)); }
rc=0;   "$PORTS" stop --yes $((BASE+6)) >/dev/null 2>&1 </dev/null || rc=$?
  (( rc == 3 )) || { echo "  FAIL stopping the fake database with --yes exited $rc, expected 3 (never bypassed)"; errors=$((errors+1)); }
rc=0;   "$PORTS" mcp </dev/null >/dev/null 2>&1 || rc=$?
  (( rc == 2 )) || { echo "  FAIL mcp while disabled exited $rc, expected 2"; errors=$((errors+1)); }
  echo '{"mcpEnabled": true}' > "$PORTS_SUPPORT_DIR/settings.json"
  mcp_out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_ports","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"stop_port","arguments":{"port":'$((BASE+0))'}}}' | "$PORTS" mcp)
  print -r -- "$mcp_out" | python3 -c '
import json, sys
r = [json.loads(l) for l in sys.stdin if l.strip()]
assert [x["id"] for x in r] == [1, 2, 3, 4], r
assert "stop_port" in json.dumps(r[1]) and "list_ports" in json.dumps(r[1])
assert "schemaVersion" in r[2]["result"]["content"][0]["text"]
assert r[3]["result"]["isError"] and "Refused" in r[3]["result"]["content"][0]["text"]
' || { echo "  FAIL MCP stdio session"; print -r -- "$mcp_out" | head -c 600; errors=$((errors+1)); }
  "$PORTS" preflight $((BASE+0)) >/dev/null && { echo "  FAIL MCP stop_port stopped :$((BASE+0)) although stop is off"; errors=$((errors+1)); }
  unset PORTS_SUPPORT_DIR

  cleanup
  for _ in {1..100}; do [[ -z "$(listening)" ]] && break; sleep 0.1; done
  if left=$(listening) && [[ -n "$left" ]]; then
    echo "  FAIL listeners left after cleanup:"; echo "$left"; errors=$((errors+1))
  fi
  if (( errors > 0 )); then
    echo "\nports list (harness ports):"; print -r -- "$TABLE"
    echo "dev_harness --check: $errors failure(s)"; exit 1
  fi
  echo "dev_harness --check: all scenarios as expected; no listeners left on $BASE–$LAST"
  exit 0
fi

say "\nports list (harness ports only):"
say "$TABLE"
say "\nAfter any stop, the app should report \"Port N is free\" or \"Still listening: …\"."
say "On this Mac, ControlCenter on :5000/:7000 (AirPlay Receiver) shows in the Developer view with an explanation."
say "\nOpen the Ports menu to check each row. Ctrl-C to stop the harness."
echo READY
while true; do sleep 3600 & wait $!; done      # wait is interruptible, so the trap runs at once
