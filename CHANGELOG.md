# Changelog

All notable changes to this project will be documented here.

## [Unreleased]

- Added Swift Package Manager structure with shared `PortsCore`.
- Added characterization tests and CI.
- Added initial open-source governance documentation.

### Phase 9 — web probing (lightweight)
- Rows read "200 · 34 ms · My App". The probe is one `GET /` after the
  scheme check: plain HTTP over a loopback socket, HTTPS through
  Network.framework (self-signed certificates accepted for this probe only).
  It records the status code, response time, `Server` header and `<title>`
  (first 64 KB, entities decoded).
- Probe rules: only while the menu is open (or `ports list --probe`), only on
  loopback, 0.8 s per listener, at most 4 at once, re-probed after 30 s.
  Never against databases, tunnels or LAN-only binds.
- JSON API badge for JSON responses.
- Copy URL and Copy host:port.
- Network-reachable servers get Copy LAN URL (the Mac's current LAN IP) and
  Show QR Code for Phone (CoreImage). Loopback-only servers get the flag that
  exposes them: `vite --host`, `next dev -H 0.0.0.0`, `runserver 0.0.0.0:8000`
  and the like.
- Search the Web for This Port opens a search with the port and process name
  only, never paths or arguments.
- No thumbnails or rendered previews (non-goal).

### Phase 8 — tunnels and forwards (display only)
- `ssh -L/-R/-D` are parsed, including the glued (`-L8080:h:80`), bind address
  and IPv6 forms. Forward rows read "Forward → db:5432 via bastion" or "SOCKS
  proxy". `ssh -R` marks the local port it exposes ("Reachable on bastion
  :8080").
- `kubectl port-forward` rows read "k8s · ns/svc/web 8080→80".
- gcloud IAP tunnels, AWS SSM port forwarding, cloud-sql-proxy and Tailscale
  are recognised and described.
- ngrok: the agent's local API (`/api/tunnels`) gives the public URL, shown on
  the row of the local port it forwards (PUBLIC badge, Copy Public URL).
- cloudflared: quick (`tunnel --url …`) and named (`tunnel run <name>`)
  tunnels. The quick tunnel's hostname comes from cloudflared's metrics
  server (`/quicktunnel`).
- Both local APIs are read only while the menu is open (or with
  `ports list --probe`): loopback only, read-only, 0.8 s.
- Ports never starts, changes or reconnects a tunnel. Stop stops the process.

### Phase 7 — databases
- Databases are recognised by their process, by container image (postgres,
  redis, mysql/mariadb, mongo, …), or by a read-only handshake on an unknown
  port. Handshakes:
  - PostgreSQL SSLRequest, a MySQL greeting read, Redis `PING`, a MongoDB
    `hello` OP_MSG, Memcached `version`, and the AMQP protocol header.
  - They run only while the menu is open (or with `ports list --probe`), only
    on loopback, only on your own listeners above 1023.
  - 300 ms each, 0.8 s per listener; credentials are never sent.
  - They never run against a listener already known as a database, and that
    includes the web probe.
- DB badge, and a red NETWORK badge for a database reachable from the
  network, plus a critical Doctor issue.
- Open in Database Client…: the apps that can open the connection URL
  (`NSWorkspace.urlsForApplications`). Known clients are listed first. The
  first choice is remembered per database type, and Open With lists the
  others.
- Copy Connection URL (`postgres://127.0.0.1:5432`, never with a user or
  password) and Copy `psql` / `mysql` / `redis-cli` / `mongosh` command.
- Safe stop keeps the Phase 1 data-store tier: 15 s grace and a separate Force
  step. brew-managed databases stop through brew services (Phase 5).

### Phase 6 — containers
- Finds every runtime's Engine API socket, in order: `DOCKER_HOST` (unix
  only), the Docker CLI's current context, Docker Desktop, `/var/run`,
  OrbStack, Colima profiles, Lima instances, Rancher Desktop, and Podman
  machines (4.x and 5.x locations). Duplicates by symlink are dropped.
- A small HTTP/1.1 client over the unix socket: 2 s timeout, Content-Length
  and chunked bodies, 8 MB cap. It is read-only except container stop and
  restart. The CLI remains a fallback when no socket answers.
- Rows behind a runtime's port proxy show `container · image · compose
  project/service · health`. Only proxies can carry a container, and with
  several runtimes the proxy's own runtime wins.
- Stop Container (Engine API), Restart Container…, Stop Compose Project (the
  confirmation lists every container), and Copy `docker logs -f <name>`.
- Containers published on all interfaces get a warning line suggesting
  `127.0.0.1:<port>:<port>`, plus a Doctor issue (critical for database
  images).
- Polling: the engine is asked only when a runtime's proxy is listening. That
  means every time the menu opens, at most every 15 s while it is closed, and
  at once when the proxy listeners change. The footer shows which runtimes
  answer and how many containers run.

### Phase 5 — stopping, supervisors and lifecycle
- PortsCore is split into the spec's folders: Model, Scan, Detect, Docker,
  Actions, Web, Store.
- Stop goes through whatever supervises the process. Every confirmation
  states what stops, how, whether it restarts automatically, and whether the
  change persists after the next login.
  - brew services: Stop Until Next Login (`brew services kill`) or Stop and
    Disable (`brew services stop`).
  - Your LaunchAgents: `launchctl bootout gui/<uid>/<label>`. Apple's jobs
    are refused.
  - pm2: `pm2 stop <id>`.
  - nodemon: the watcher and its children are stopped, so nothing respawns.
  - Containers: `docker stop`.
  - Apps: quit like ⌘Q.
  - System processes that launchd restarts: an explanation instead of Kill.
- Stop Process and Its Children / Stop All Workers. A process holding several
  ports lists the ports it frees.
- Stop Several…: one confirmation for checked rows, each with its exact
  signals.
- Pause / Resume (SIGSTOP / SIGCONT), with a PAUSED badge for processes Ports
  paused.
- Protect Port: stopping a protected port needs its number typed in.
- A second Stop of the same process within 2 minutes offers Force Quit at
  once.
- Check Port… and `ports preflight <port>`: a bind probe on 127.0.0.1, ::1 and
  0.0.0.0. When no visible process holds the port, it says a process macOS
  doesn't expose holds it. Find Free Port… and `ports next-free [--from N]`.
- Run Start Command in Terminal opens a visible Terminal window, never a
  hidden process. There is no in-app restart.
- Settings store (`settings.json`, tolerant of older files).
- Fixed: the web-probe answer tests could time out under parallel load. They
  now use a test-only budget; the 0.8 s production budget is still tested.

### Phase 4 — orphans, coding agents, duplicates, doctor
- "Started by": the first meaningful ancestor, from a data table of coding
  agents (Claude Code, Cursor agent, Codex, Gemini, Aider, Antigravity,
  Windsurf, Copilot, OpenCode, Kiro), editors, terminals, tmux/screen, pm2,
  nodemon and launchd jobs.
- Orphan verdicts (confirmed, likely, possible, not an orphan), each with
  plain-English evidence and a Safe to stop? answer (green, yellow, red).
  Signals:
  - adopted by launchd without being a launchd job
  - terminal session gone, or no terminal at all
  - the agent that started it has exited
  - another instance running, idle, or suspended

  Never flagged: launchd jobs and brew services, pm2, containers, apps in
  `/Applications`, anything a live terminal, editor or agent still runs, SSH
  sessions, starred services.
- Leftovers: orphaned watchers and MCP servers that hold no port (`tsc -w`,
  `esbuild --watch`, vitest, …). They appear only when they meet the strict
  rules.
- Duplicate detection (same project and framework twice) with a TWICE badge
  and Stop the Older One.
- Health section from Doctor: orphans, duplicates, databases reachable from the
  network, suspended or idle servers, a container runtime that doesn't answer,
  and localhost resolving to ::1 while a server binds only 127.0.0.1 (or the
  reverse).
- Clean Up Leftovers… lists exactly what will be signalled. Confirmed
  orphans are checked and likely ones are opt-in. It uses the same stop core
  as everything else (StopRegistry, identity check, SIGKILL only for dev
  servers).
- Star (never flag as orphan), Copy Setup Prompt for AI, and ORPHAN/TWICE
  badges in the menu and in `ports list`.
- `Scripts/check.sh` runs every gate. The harness gained an orphan, a
  duplicate, an orphaned `tsc -w`, and an owner-run `--with-launchd`
  LaunchAgent scenario.

### Phase 3 — detection and classification
- Framework table (`Frameworks.swift`) with about 120 entries: frontend
  tools, backend frameworks, databases and brokers, tunnels, AI servers. Each
  entry has matchers, a category, a display name, a default port and whether
  it speaks HTTP. Some frameworks are recognised by argv (`manage.py
  runserver`, `php artisan serve`, `next dev --turbo`), some by the launching
  parent (`go run`, `cargo run`), some by package.json dependencies (Express,
  Nest, Fastify, Hono, Koa), and some by a bundled runtime (Kibana, LM Studio).
  Directory names are still never used.
- New categories: Containers (was Docker), Tunnels & forwards, AI & agents
  (model servers, MCP servers), Background services (your launchd jobs), Apps
  (split from System).
- Each row has a confidence score (0–100) and a safety tier (safe, warning,
  blocked), shown in its details.
- Known-ports table: owner, explanation and how to free it, for AirPlay,
  common dev defaults, database ports, the ngrok inspector, CUPS, Kerberos,
  SMB/AFP, Docker/Kubernetes APIs and the ephemeral range. `ports list` prints
  the explanation under a system process that holds a dev port.
- Customize menu on every row: Rename, Move to (category), Note, Link to App,
  Favorite, Hide, Mute, Reset. Stored in
  `~/Library/Application Support/Ports/overrides.json`. An override changes how
  a row is shown, never how it is stopped or probed.
- Row icons: the owning app's icon, else the project's `public/` or `static/`
  favicon, else the category symbol.

### Phase 2 — richer process model
- Each listener now records its parent PID, process group, controlling
  terminal and launcher chain (parent → … → launchd). The menu shows
  "Started by …".
- Memory, CPU time, uptime ("running 2 d 4 h") and the number of open
  connections ("Idle" when there are none). CPU % is sampled only while the
  menu is open.
- Prefork servers (gunicorn, uvicorn workers, cluster mode) collapse into one
  row with a worker count (`×3`). Workers count only when they hold the same
  inherited socket, so IPv4/IPv6 owners stay separate.
- Project and branch: walks up from the working directory (or the script being
  run) to the nearest manifest and names the project from it. Monorepos show
  `repo › package`. The git branch is read from `.git/HEAD` (worktrees and
  detached HEAD supported); no git process is started. Labels read
  `tool · project · branch`.
- Copy Start Command (`cd '<cwd>' && <argv>`, shell-quoted).
- `ports list --timing` prints the warm scan time; `ports list --env` prints
  your own processes' environment with secret-looking values masked, when
  macOS provides it.
- Static per-process data is cached by PID + start time, so a warm scan only
  reads what can change.
- Fixed: the web-probe cache kept entries for exited processes forever.
- Child processes are now launched only from `Exec.swift`.

### Phase 1 — correctness and safety

- Show the real bind address. New `Exposure` model (`loopback`, `allInterfaces`,
  `specific(ip)`). A port bound to a specific LAN address is now flagged as
  reachable from the network.
- Classify by executable name, argv[0], the script or module being run,
  `node_modules/.bin/<tool>`, `npx <tool>` and known runner subcommands, never
  by directory names in paths.
- Detect OrbStack, Colima/Lima, Rancher Desktop and Podman as well as Docker
  Desktop. Look for their CLIs in `~/.orbstack/bin`, `~/.rd/bin` and
  `/opt/homebrew/bin/podman`. Query containers whenever a runtime's proxy is
  listening.
- Container labels are refreshed in the same scan and apply only to
  container-runtime proxies. A native process on a reused port no longer
  offers "Stop container".
- Kill by Port rescans first. If several processes own the port, it lists them
  all and lets you choose.
- Suspended processes show a Stopped badge. Stopping one sends SIGTERM, then
  SIGCONT so it can exit.
- Safety tiers: only Frontend/Backend dev servers are SIGKILLed automatically,
  after 2 s. Apps and helpers (System & Apps) and the container engine get 5 s;
  databases and brokers get a data-loss warning and 15 s. None of those is ever
  force-killed automatically; Force Quit is a separate, explicit step.
- After every stop, Ports rescans and reports "Port N is free" or
  "Still listening: …".
- System processes on common dev ports are shown in the Developer view with an
  explanation (e.g. ControlCenter on 5000/7000 is AirPlay Receiver, and how to
  turn it off).
- "Open in Browser" appears only for listeners that answer HTTP, and uses https
  when the server speaks TLS.
- Added `Scripts/dev_harness.sh`, which starts throwaway listeners for each of
  these scenarios.
- Detect RabbitMQ and CouchDB on the Erlang VM (`-s rabbit`, `-boot`,
  `-progname`), and Neo4j and other JVM stores even when `--add-opens` comes
  before the main class.
- `ports list` marks suspended processes `STOPPED`, like the menu.
- The web probe runs only while the menu is open, only on loopback, within
  0.8 s per listener, and never on Databases.
- Fixed (since Phase 0): on case-insensitive APFS the CLI overwrote the app
  binary, so the bundle contained only the CLI. The CLI now lives in
  `Contents/Helpers/ports`, and `build_app.sh` fails if the two binaries are
  missing or identical, or if the app doesn't link AppKit.
- `dev_harness.sh` refuses to start if its ports are taken, and always kills its
  own children on exit, including a suspended or TERM-ignoring one.
- Only one stop flow runs per process. A repeated request brings the open alert
  forward instead of starting a second ladder.
- Row detail and the Kill by Port chooser show each process's own bind
  addresses.
- The AirPlay Receiver tip names the pane for your macOS version ("AirDrop &
  Continuity" on macOS 26, "AirDrop & Handoff" before) and adds Open AirPlay Settings. System
  owners that launchd restarts (ControlCenter, rapportd, …) are not offered
  Kill.
