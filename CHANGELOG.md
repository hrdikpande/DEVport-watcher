# Changelog

All notable changes to this project will be documented here.

## [Unreleased]

- Added Swift Package Manager structure with shared `PortsCore`.
- Added characterization tests and CI.
- Added initial open-source governance documentation.

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
