# Implementation prompt — DEVport-watcher ("Ports") full build-out

> Paste everything below this line into your coding agent (Claude Code, Cursor, etc.) from the root of the
> `DEVport-watcher` repository. Run it **one phase per session**: tell the agent "Do Phase N only", review,
> merge, then start the next phase. Every phase is self-contained and has its own acceptance criteria.

---

## 0. Who you are and what you are working on

You are a senior macOS engineer working in the repository `hrdikpande/DEVport-watcher`. Today it is a
single-file Swift/AppKit menu bar app (`main.swift`, ~583 lines, macOS 14+) called **Ports** that:

- enumerates listening TCP sockets with libproc (`proc_listallpids`, `PROC_PIDLISTFDS`, `PROC_PIDFDSOCKETINFO`),
  reads exe path, argv (`KERN_PROCARGS2`), cwd and start time;
- classifies listeners into Frontend / Backend / Databases / Docker / System & Apps using hard-coded tool lists;
- shows them in an `NSMenu` from an `NSStatusItem`, polls every 10 s, shows a dev-listener count;
- kills only the user's own processes with SIGTERM → SIGKILL after 2 s, re-checking PID start time;
- maps Docker Desktop published ports to container names by running `docker ps` from fixed paths and can
  `docker stop` a container;
- has `Ports --list` for a text table;
- is built by `build.sh` with `swiftc`, ad-hoc signed, installed to `~/Applications`.

Your job is to turn it into the most complete **local dev-port manager for macOS**, combining the best features
of PortKiller, LeftOpen, Portreaper, devclean, Portpourri, Porthole, portctl (Rust and Python), Seeports,
Portolan, Bosun and ports-cli — **without** becoming a Kubernetes client, tunnel manager, VPN client,
firewall manager or dev-stack orchestrator (see §14 Non-goals).

## 1. Product principles (apply to every phase)

1. **The menu bar is the whole product.** Every feature must be reachable from the status item: its panel,
   its right-click/Option menus, or the Settings window opened from it. No Dock icon (`.accessory`), no
   always-open windows. The CLI and MCP server are *secondary* interfaces for scripts and coding agents;
   they are installed and switched on/off from the menu bar.
2. **Zero configuration, everything auto-detected.** Docker runtimes, database clients, supervisors
   (launchd / brew services / pm2 / nodemon / Docker), coding agents, editors, terminals, projects, git
   branches, tunnels and well-known system ports are discovered automatically. Settings only refine.
3. **Optimized for MacBooks.** Near-zero CPU when the panel is closed, no wake-ups the OS can't coalesce,
   no network probes unless the panel is open, scanning pauses while the Mac sleeps or the screen is locked,
   slower polling on battery / Low Power Mode. Universal binary (arm64 + x86_64).
4. **Safety beats convenience.** Keep and extend every existing guard: start-time identity check before every
   signal, own-UID only, never PID 1 / self, no shell, fixed absolute executable paths, argv arrays, minimal
   environment, timeouts. Nothing is ever killed automatically. Destructive actions always confirm, and the
   confirmation states exactly what will happen (signal, supervisor command, container stop).
5. **Local only.** No telemetry. The only optional outbound request is a daily GitHub release check that is
   **off by default**.
6. **No new third-party runtime dependencies** except `swift-argument-parser` for the CLI. Use AppKit,
   SwiftUI, Darwin, Foundation, UserNotifications, ServiceManagement, Network, Carbon (hot key only).
7. **Name lives in one place.** The app may be renamed (the name "Ports" collides with other open-source
   apps). Put the display name, bundle ID, CLI name and support-folder name in a single `Brand.swift`
   so a rename is a one-file change. Default values: display name `Ports`, CLI `ports`, bundle id
   `io.github.hrdikpande.ports`.

## 2. Rules for how you work

- Do **only the phase you were asked for**. If you see a problem in a later phase's scope, note it in
  `docs/NOTES.md` instead of fixing it.
- Before writing code, read the current sources and write a short plan (files to add/change, risks).
- Each phase must end with: `swift build -c release` passing, `swift test` passing, the app launching,
  the phase's acceptance checklist ticked in the PR description, and `CHANGELOG.md` updated.
- Write fixture-based unit tests for every parser, classifier and decision function. No test may require
  Docker, network or root; integration checks go in `Scripts/dev_harness.sh`.
- Never weaken a safety guard to make a test pass. If something is impossible without root, show a clear
  "needs administrator" explanation in the UI instead of a silent gap.
- Where this prompt says **verify**, check the fact at runtime/in docs before relying on it, and fall back
  gracefully if it is wrong.
- Commit messages: `phase-N: <what>`.

## 3. Target architecture (created in Phase 0, filled in later phases)

```
Package.swift                 # swift-tools-version 5.10+, macOS 14, universal
Sources/
  PortsCore/                  # NO AppKit/SwiftUI imports. Pure, testable.
    Model/        Listener.swift, ProcessInfo.swift, Exposure.swift, Verdict.swift, Category.swift
    Scan/         SocketScanner.swift (libproc), ProcessReader.swift (argv, cwd, kinfo_proc, task info),
                  ProcessTree.swift, ConnectionCounter.swift, BindProbe.swift, ScanCache.swift
    Detect/       Classifier.swift, Frameworks.swift (data table), KnownPorts.swift (data table),
                  ProjectResolver.swift, GitInfo.swift, SupervisorDetector.swift, AgentDetector.swift,
                  OrphanAnalyzer.swift, TunnelDetector.swift, DatabaseDetector.swift
    Docker/       DockerRuntimeLocator.swift, DockerEngineClient.swift (HTTP over unix socket),
                  DockerCLIFallback.swift, ContainerMapper.swift
    Actions/      Terminator.swift (safe kill ladder), SupervisorStop.swift, ProcessControl.swift
                  (pause/resume), CommandRecall.swift
    Web/          HTTPProbe.swift
    Store/        Settings.swift, History.swift (JSONL), Overrides.swift
    Snapshot.swift            # one immutable snapshot of the machine; diffable
    SnapshotService.swift     # schedules scans, adaptive cadence, emits diffs
    Doctor.swift              # health-check issues
    Exec.swift                # the ONLY place that launches child processes (fixed paths, argv, env, timeout)
  PortsApp/                   # AppKit status item + SwiftUI panel + Settings window
    AppDelegate.swift, StatusItemController.swift, PanelView/*.swift, SettingsView/*.swift,
    Notifications.swift, HotKey.swift, LoginItem.swift, CLIInstaller.swift, Brand.swift
  ports/                      # CLI executable (swift-argument-parser), also hosts `ports mcp`
    main.swift, Commands/*.swift, MCP/*.swift
Tests/
  PortsCoreTests/             # fixtures in Tests/PortsCoreTests/Fixtures/*.json|txt
Scripts/
  build_app.sh                # replaces build.sh: universal build, bundle, sign, (optionally) notarize
  dev_harness.sh              # starts real listeners for manual checks (see Phase 1)
  release.sh                  # notarytool + staple + zip/dmg
.github/workflows/ci.yml, release.yml
docs/ ARCHITECTURE.md, FEATURES.md, NOTES.md
LICENSE, CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md, CHANGELOG.md, README.md
```

The app and the CLI both use `PortsCore`, so classification, verdicts and safety rules are identical
everywhere. The CLI binary is embedded at `Ports.app/Contents/MacOS/ports`.

---

## Phase 0 — Repository, license, structure, CI (no behaviour change)

1. Add `LICENSE` (MIT, copyright `<YEAR> <COPYRIGHT HOLDER>` — leave the placeholders for the owner),
   `CONTRIBUTING.md`, `SECURITY.md` (how to report; explain the app signals processes), `CODE_OF_CONDUCT.md`
   (Contributor Covenant), `CHANGELOG.md` (Keep a Changelog).
2. Remove committed build output and junk: `build/`, every `.DS_Store`, `archive/` (move `main-v1.swift` to a
   git tag, not the tree). Add `.gitignore` (`.build/`, `build/`, `.DS_Store`, `*.xcuserstate`, `dist/`).
3. Create the Swift package and module layout from §3. Move existing code into `PortsCore` / `PortsApp`
   **without changing behaviour**. `Ports --list` keeps working (now `ports list`).
4. `Scripts/build_app.sh`: `swift build -c release --arch arm64 --arch x86_64`, assemble `.app`, copy
   `Info.plist` (add `LSUIElement=YES`, `LSMinimumSystemVersion=14.0`, the bundle id from `Brand`),
   icon, embed the CLI, sign with hardened runtime (ad-hoc unless `DEVELOPER_ID` env var is set).
5. CI (`ci.yml`, macos-latest): build, test, build the app bundle.
6. Write `docs/ARCHITECTURE.md` and copy the feature list from §15 into `docs/FEATURES.md` as a checklist.

**Accept when:** the repo builds with `swift build`, the app behaves exactly as before, CI is green,
no binaries are tracked.

---

## Phase 1 — Correctness and safety fixes (P0)

Fix these defects in the current behaviour. Add a regression test for each.

1. **Exposure/bind address.** Today only `0.0.0.0`/`::` count as exposed. Record the actual bind address of
   every listening socket (IPv4 and IPv6). Model it as `Exposure`: `.loopback(127.0.0.1 / ::1)`,
   `.allInterfaces`, `.specific(ip)`; `.specific` with a non-loopback IP counts as reachable from the network.
   Show the real address in the UI ("Local only · 127.0.0.1", "Network · 0.0.0.0", "Network · 192.168.1.5").
2. **Folder-name misclassification.** The classifier currently tokenises the command line on `/`, so a path like
   `~/work/astro-dashboard/app.py` becomes "astro". Rewrite classification to look at: executable basename,
   argv[0] basename, the **script/module argument** (e.g. the `.js`/`.py`/`.ts` file, `-m module`,
   `node_modules/.bin/<tool>`, `npx <tool>`), and known subcommands (`next dev`, `vite`, `manage.py runserver`).
   Never match directory names in paths. Fixtures must include the misclassification cases.
3. **Docker gate bug.** Container lookup currently only runs if some listener was already classified as Docker,
   which only Docker Desktop paths trigger. Instead, query the Docker runtime whenever a runtime is detected
   (Phase 6 makes detection complete; here, at minimum, also treat OrbStack, Colima/Lima (`limactl`, `ssh`
   port-forward children of lima), Rancher Desktop and Podman helper processes as container proxies, and add
   `~/.orbstack/bin/docker`, `~/.rd/bin/docker`, `/opt/homebrew/bin/podman` to the lookup).
4. **Stale container labels.** Container mapping must be refreshed in the same scan cycle as the sockets, and a
   listener is only labelled with a container if its owning process is a container proxy. A native process on a
   port that a stopped container used must never show "Stop container".
5. **Kill-by-port ambiguity.** Kill by port must rescan first, and if more than one process listens on the port
   (IPv4 vs IPv6, SO_REUSEPORT, AirPlay + Flask on 5000), show all owners and let the user pick.
6. **Ctrl-Z / stopped processes.** Read process state (`kinfo_proc` via `sysctl KERN_PROC_PID`, `p_stat == SSTOP`).
   Show a "Stopped" badge. The kill ladder sends `SIGTERM` then `SIGCONT` so a stopped process can exit.
7. **Databases are not SIGKILLed after 2 s.** Kill ladder per safety tier: dev servers 2 s grace; databases and
   message brokers 15 s grace and a confirmation that warns about data loss; never SIGKILL a database
   automatically — offer "Force quit" as a second explicit step.
8. **Confirm the port is free.** After any stop action, rescan that port and report "Port 3000 is free" or
   "Still listening: <owner>" with a Force option.
9. **AirPlay and other system holders on dev ports.** Never hide a system process that listens on a common dev
   port. In the Developer view, show it with an explanation from `KnownPorts` (see Phase 3), e.g. ControlCenter
   on 5000/7000 → "AirPlay Receiver. Turn it off in System Settings → General → AirDrop & Handoff".
10. **Open in Browser** only for HTTP-like listeners; try `https` when the server speaks TLS (Phase 9 refines).
11. `Scripts/dev_harness.sh`: starts listeners for manual checks — `python3 -m http.server` on 127.0.0.1, on
    0.0.0.0 and on the Mac's LAN IP; two listeners on one port (IPv4 + IPv6); a server in a folder named
    `astro-dashboard`; a process stopped with SIGSTOP; an orphan (start via a subshell, then kill the subshell);
    cleans everything up on exit.

**Accept when:** all ten defects have tests, the harness shows correct exposure, owners and badges, and no
existing safety guard was removed.

---

## Phase 2 — Richer process model (detail, tree, metrics, project, git)

Extend `Listener`/`ProcessInfo` and the scanner. Cache per-process static data keyed by `(pid, startTime)`
so each scan only reads what can change.

1. **Parent PID and tree.** Read `ppid` (`pbi_ppid`), process group, controlling TTY (`e_tdev`), UID, state.
   Build the launcher chain for every listener (this process → parent → … → launchd), with each ancestor's
   name and exe.
2. **Metrics.** Resident memory and CPU time from `PROC_PIDTASKINFO`; CPU % from two samples (only while the
   panel is open); start time → uptime ("running 2 d 4 h").
3. **Connections.** From the same fd scan, count established TCP connections whose local port equals the
   listening port → "idle" when 0.
4. **Multi-worker grouping.** Listeners sharing one port across a parent and its worker children (gunicorn,
   uvicorn workers, Odoo, cluster mode) collapse into one row with a worker count.
5. **Project resolver.** Walk up from cwd (and from the script argument's directory) to the nearest
   `.git`, `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Gemfile`, `composer.json`, `pom.xml`,
   `build.gradle*`, `deno.json`, `bun.lockb`; use the manifest's project name if present, else the folder name.
   Support monorepos (show `repo › package`). Works anywhere, not only under `$HOME`.
6. **Git branch.** Read `.git/HEAD` directly (no `git` process); support worktrees (`.git` file with
   `gitdir:`), detached HEAD (short SHA). Show `project · branch`.
7. **Startup command recall.** Keep the full argv and cwd so the UI can "Copy start command"
   (`cd '<cwd>' && <argv shell-quoted>`). Never capture or show environment variables in the app; the CLI may
   show env names only with `--env` and must mask values that look like secrets.
8. **Environment detail (CLI only):** see 7.

**Accept when:** detail data is correct on the harness, a full scan with 300+ processes completes in
< 30 ms on Apple Silicon after warm-up (measure and print in `ports list --timing`), and memory stays < 40 MB.

---

## Phase 3 — Detection and classification

1. **Frameworks table** (`Frameworks.swift`, data-driven, easy to extend, each entry: matchers, category,
   display name, default port, is-HTTP, safety tier). Cover at least: Vite, Next.js (incl. `next-server`),
   Nuxt, Astro, Remix, SvelteKit, Gatsby, Angular CLI, Create React App/react-scripts, Webpack dev server,
   Parcel, Storybook, Expo/Metro, Eleventy, live-server, http-server, serve, Turbopack, esbuild serve,
   Express, Nest, Fastify, Hono, Deno, Bun, nodemon, tsx/ts-node, Django runserver, Flask/Werkzeug,
   FastAPI/Uvicorn, Hypercorn, Gunicorn, Tornado, Jupyter, Streamlit, Gradio, Rails/Puma, Sinatra, Phoenix,
   Laravel/`php artisan serve`, PHP built-in server, Spring Boot, Tomcat, Jetty, Quarkus, .NET/Kestrel,
   Go (`go run`, air), Rust (`cargo run`, trunk), Hugo, Jekyll, Strapi, Supabase, Hasura, PostgREST, n8n,
   Airflow, Kibana, Prometheus, Grafana, Jaeger, Ollama, LM Studio, Mailhog/Mailpit, MinIO, Portainer,
   Nginx, Caddy, Traefik, Apache httpd, Wrangler/workerd, Firebase emulators, LocalStack, ngrok agent API,
   cloudflared.
2. **Category model:** Frontend, Backend, Databases, Containers, Tunnels & forwards, AI & agents (model
   servers, MCP servers), Background services (launchd-managed), Apps, System. Each row also carries
   **who started it** (Phase 4) and a **safety tier**: `blocked` (PID 0/1, launchd, kernel, other users),
   `warning` (databases, brokers, Docker engine, apps, system daemons), `safe` (dev servers).
3. **Confidence** 0–100 for each classification, shown in the detail view and JSON.
4. **Known ports table** (`KnownPorts.swift`): port → likely owner → explanation → how to free it. Include
   5000/7000 AirPlay (ControlCenter), 3000/5173/8080/8000 common dev defaults, 5432/3306/6379/27017/9200/
   5672/9092/11211/1433/8123/9000, 4040 ngrok API, 631 CUPS, 88/445/548 system services, 49152+ ephemeral,
   Docker Desktop's own ports.
5. **User overrides** (Settings + row context menu): rename a service, move it to another category, link it
   to an app (for icon/open), set a custom label/note, mark as favorite, hide, mute.
6. **Icons:** owning `.app` icon via `NSWorkspace.icon(forFile:)`; else project favicon (`public/favicon.*`,
   `static/favicon.*`) read from disk; else SF Symbol for the category. Nothing bundled per vendor.

**Accept when:** fixture tests cover every framework matcher and the misclassification cases, and the
known-port explainer appears for AirPlay on the harness.

---

## Phase 4 — Orphans, coding agents, duplicates, doctor

1. **Starter attribution** (`AgentDetector`): walk the launcher chain and tag the first meaningful ancestor:
   coding agents (Claude Code `claude`, Cursor agent/terminal, Codex CLI, Gemini CLI, Aider, Antigravity,
   Windsurf, Copilot CLI, OpenCode, Kiro), editors (VS Code incl. `Code Helper`, Cursor, Zed, JetBrains IDEs,
   Xcode, Nova), terminals (Terminal.app, iTerm2, Warp, Ghostty, kitty, WezTerm, Alacritty), multiplexers
   (tmux, screen), supervisors (launchd job, brew services, pm2, nodemon, Docker), or `unknown`. Data-driven list.
2. **Orphan analyzer** (`OrphanAnalyzer`) — verdicts `confirmed`, `likely`, `possible`, `not orphan`, each with
   plain-English evidence lines. Signals: reparented to PID 1 **and** not a launchd job; launcher chain ends at
   a dead shell or dead terminal session (TTY gone); no controlling TTY for a dev-server command line; the
   agent/editor that started it is no longer running; duplicate instance of the same project + command;
   idle (0 connections) for > N minutes; stopped (Ctrl-Z). **Exclusions (never flagged):** launchd jobs,
   brew services, pm2-managed processes, Docker, apps in `/Applications` or `~/Applications`, anything with a
   live terminal behind it, anything starred. A script runtime is judged by its script, not by its install path.
3. **"Safe to stop?"** answer per row: green (nothing owns it), yellow (duplicate or weak evidence),
   red (a live launcher still owns it).
4. **Orphans without ports** (e.g. leftover `electron-vite`, `tsc -w`, `esbuild --watch`, MCP servers whose
   parent agent died) appear in a separate "Leftovers" section, flagged only by the strict rules above.
5. **Duplicate detection:** same project root + same framework running more than once (e.g. on 3000 and
   3001) → "Running twice" badge, with "Stop the older one" action.
6. **Star (whitelist)**: permanently exempt a process signature (exe + script + project) from suspicion.
7. **Bulk clean-up:** panel action "Clean up leftovers…" opens a confirmation listing every `confirmed`
   orphan (opt-in checkboxes for `likely`), shows exactly what will be signalled, then runs the safe ladder.
   Never automatic.
8. **Doctor** (`Doctor.swift`): issues list — orphans, duplicates, stopped processes, idle servers older than
   a threshold, databases exposed to the network, ports blocked by invisible owners (Phase 5 bind probe),
   watched ports taken by something else, Docker runtime unreachable, `localhost` vs `127.0.0.1`/`::1`
   mismatch (server on 127.0.0.1 only while a client resolves `localhost` to ::1). Each issue: severity,
   explanation, one-click fix if safe. Shown as a "Health" section at the top of the panel when non-empty.
9. **"Copy setup prompt for AI"**: copies a prompt telling a coding agent which ports/projects are in use and
   how to query them with the CLI/MCP (Phase 11).

**Accept when:** the harness orphan is `confirmed`, a launchd/brew service is never flagged, a duplicate
project is detected, and every verdict shows its evidence.

---

## Phase 5 — Stopping, supervisors and lifecycle

1. **Kill ladder** (`Terminator`, single code path used by app, CLI and MCP): verify identity → SIGTERM →
   SIGCONT (if stopped) → wait per tier → report. SIGKILL only on explicit Force or, for `safe` tier, after
   the grace period. A second Stop on the same process within 2 minutes offers Force immediately.
2. **Stop through the supervisor** (`SupervisorDetector` + `SupervisorStop`), the confirmation names the method:
   - brew services → `brew services stop <formula>` (fixed path `/opt/homebrew/bin/brew` or
     `/usr/local/bin/brew`); offer "Stop until next login" (`brew services kill`) vs "Stop and disable".
   - other user launchd jobs → `launchctl bootout gui/<uid>/<label>` (find label by matching ProgramArguments
     in `~/Library/LaunchAgents/*.plist`; **verify** via `launchctl print`); system/root jobs → explain,
     don't act.
   - pm2 → `pm2 stop <id>` if pm2 is installed at a fixed path; else explain.
   - nodemon / watchers → stop the watcher (parent), not the child it would respawn.
   - Docker container → `docker stop` (Phase 6); Docker engine itself → warn that all containers stop.
   - Apps → `NSRunningApplication.terminate()` (quit the app), never SIGKILL an app first.
3. **Process tree / group stop:** "Stop process and its children" and "Stop all ports of this process" and,
   for multi-worker rows, "Stop all workers".
4. **Multi-select:** select several rows (⌘-click / checkboxes) → stop together with one confirmation.
5. **Pause / Resume** (SIGSTOP / SIGCONT) for own processes, with a "Paused" badge.
6. **Protected ports** (Settings): stopping them requires typing the port number.
7. **Bind probe** ("Check port…" in the panel and `ports preflight`): try to bind 127.0.0.1, ::1 and 0.0.0.0
   on the port (no listen, close immediately). If bind fails but no visible owner exists, report
   "Held by a process macOS doesn't expose (user-space networking). Restarting the owning app or the Mac frees it."
8. **Next free port:** "Find a free port near 3000" action → copies the number.
9. **Copy start command** (from Phase 2) and **Run in Terminal** (opens Terminal/iTerm with the command via
   `NSWorkspace`/AppleScript-free URL or `open -a`, never runs it hidden). There is **no in-app restart** that
   spawns the server as the app's child.

**Accept when:** brew services and a LaunchAgent are stopped the right way and do not respawn, nodemon
does not resurrect the child, and every action reports the final port state.

---

## Phase 6 — Containers (Docker, OrbStack, Colima, Lima, Podman, Rancher)

1. **Runtime locator:** detect sockets in order — `$DOCKER_HOST`, current Docker context from
   `~/.docker/config.json` + `~/.docker/contexts/meta/*/meta.json`, `~/.docker/run/docker.sock`,
   `/var/run/docker.sock`, `~/.orbstack/run/docker.sock`, `~/.colima/<profile>/docker.sock`,
   `~/.lima/<instance>/sock/docker.sock`, `~/.rd/docker.sock`, Podman machine socket
   (`~/.local/share/containers/podman/machine/**/podman.sock`, **verify** path). Show the active runtime(s) in
   the panel footer and Settings.
2. **Engine API client** over the unix socket (small HTTP/1.1 client on Darwin sockets, 2 s timeout, read-only
   calls except stop): `GET /containers/json` → names, image, published ports (host IP + port + proto),
   state, health, labels `com.docker.compose.project` / `.service`. Fall back to the CLI (fixed paths) only if
   the socket is unavailable.
3. **Map host listeners to containers** by host port **and** proxy process (Docker Desktop backend, OrbStack
   helper, `limactl`/ssh forwarders, gvproxy, Rancher). Show `container · image · compose project/service ·
   health`.
4. **Actions:** Stop container, Restart container, Stop whole Compose project (all containers with the same
   project label; confirmation lists them), Copy `docker logs -f <name>`, Open in browser.
5. **Exposure:** flag containers published on `0.0.0.0` (a bare `5432:5432`), suggest `127.0.0.1:5432:5432`.
6. **Polling:** query the engine only when a runtime is detected, at most every 15 s while closed, on every
   panel open, and on listener changes involving a proxy process.

**Accept when:** containers on Docker Desktop and OrbStack (and Colima if available) show names, images and
compose projects; tests use recorded Engine API JSON fixtures.

---

## Phase 7 — Databases

1. **Detection:** by process (postgres, mysqld, mariadbd, mongod, redis-server, valkey-server, memcached,
   clickhouse, cockroach, influxd, elasticsearch, opensearch, neo4j, couchdb, rabbitmq/beam.smp, kafka,
   nats-server, surreal, cassandra, SQL Server in containers), by container image, and — only while the panel is
   open — by a **read-only protocol handshake** on unknown ports: PostgreSQL SSLRequest, MySQL greeting,
   Redis `PING`, MongoDB `hello`, AMQP header, Memcached `version`. 300 ms timeout, loopback only,
   never send credentials.
2. **Open in client (auto-detected):** build a connection URL (`postgres://localhost:5432`, `mysql://…`,
   `mongodb://…`, `redis://…`) and list the apps that can open it via
   `NSWorkspace.urlsForApplications(toOpen:)`; the first launch asks which client to use and remembers it
   per DB type (changeable in Settings → Databases). Known clients to recognise and prefer: TablePlus,
   Postico, pgAdmin, DBeaver, DataGrip, Sequel Ace, MySQL Workbench, MongoDB Compass, Redis Insight,
   Beekeeper Studio (**verify** each handles the scheme; fall back to "Copy connection URL").
3. **Copy connection string** and **Copy `psql`/`mysql`/`redis-cli`/`mongosh` command**.
4. **Network exposure warning:** a database bound to anything but loopback gets a red "Reachable from your
   network" badge and a Doctor issue.
5. **Safe stop:** databases use the `warning` tier from Phase 1; for brew-managed DBs use brew services.

**Accept when:** Postgres/Redis (native or container) show the right client action and the exposure badge
works on a 0.0.0.0 bind.

---

## Phase 8 — Tunnels and forwards (detect and display; no management)

1. **SSH -L / -R forwards:** parse `ssh` argv (`-L [bind:]port:host:hostport`, `-R`, `-D`) and show
   "Forward → host:port" on the listening row; Stop = stop that ssh process.
2. **ngrok:** detect the agent process; read `http://127.0.0.1:4040/api/tunnels` (only while panel open) to
   show the public URL next to the local port it forwards. Copy public URL.
3. **Cloudflare:** detect `cloudflared` (`tunnel --url …` quick tunnels and `tunnel run` named tunnels),
   show the local target; **verify** whether cloudflared's local metrics server exposes the quick-tunnel
   hostname and show it if so. Copy public URL.
4. **kubectl port-forward:** detect `kubectl port-forward` processes, parse resource and ports, group under
   "Tunnels & forwards" as "k8s · svc/name 8080→80". Stop = stop that kubectl process. No session management.
5. Other forwarders recognised by name: `gcloud … iap-tunnel`, `aws ssm start-session` port forwarding,
   `cloud-sql-proxy`, Tailscale serve/funnel (display only).

**Accept when:** an `ssh -L 15432:db:5432` and a `kubectl port-forward` (fixture argv) render correctly.

---

## Phase 9 — Web probing and previews (lightweight)

1. **HTTP probe** (only while the panel is open, loopback only, 800 ms timeout, max 4 concurrent, cached 30 s):
   try HTTP then HTTPS (TLS errors from self-signed certs accepted for the probe only), record status code,
   response time, `Server` header, and `<title>` from the first 64 KB. Show "200 · 34 ms · My App" on the row.
2. **Open in Browser** uses the detected scheme; for JSON responses show "JSON API" badge.
3. **Copy URL**, **Copy host:port**, **Copy LAN URL** (for network-exposed servers, using the Mac's current
   LAN IP) and **Show QR code** for the LAN URL (CoreImage `CIQRCodeGenerator`) for phone testing; if the
   server is loopback-only, explain how to expose it (e.g. `vite --host`).
4. **Search the web** for unknown port/process (opens a search URL in the browser).
5. No thumbnails or rendered previews (energy cost) — see Non-goals.

---

## Phase 10 — Menu bar UI, organisation, notifications, history, settings

Replace the `NSMenu` with an `NSStatusItem` + `NSPopover` (or `NSPanel`) hosting SwiftUI. Right-click on the
status item shows a small classic menu (Refresh, Pause scanning, Settings…, Quit).

**Status item**
- Icon + count of dev listeners (configurable: dev count / all / none). A small red dot when Doctor has issues
  or a confirmed orphan exists. Tooltip summarises.

**Panel layout (top → bottom)**
1. Search field (filters by port, process, framework, project, branch, container, title; `/` focuses).
   Filter chips: Developer · All · Favorites · Leftovers · Containers · Databases · Tunnels.
   Sort menu: category (default), port, project, uptime, memory.
2. **Health** section (Doctor issues, collapsible) with one-click fixes.
3. **Favorites** (pinned rows).
4. Category sections with counts. Each row: icon, `:port`, name (`framework · project · branch`),
   badges (`LAN`, `NEW`, `Orphan`, `Running twice`, `Stopped`, `Paused`, `Idle`, `Container`, `DB`),
   status (HTTP code / response time), uptime. Hover shows the inline Stop button.
5. Expanding a row (or →) shows detail: PID, bind address, exposure explanation, cwd (click to reveal in
   Finder), command, launcher chain, started by, memory, CPU, uptime, connections, container/compose info,
   tunnel info, verdict evidence, "Safe to stop?", and actions: Open, Open in DB client, Copy URL/host:port/
   LAN URL/QR, Copy start command, Run in Terminal, Copy PID, Reveal executable, Stop (method named),
   Force quit, Pause/Resume, Stop tree / all ports / all workers, Stop container / compose project,
   Favorite, Hide, Mute, Star (never flag), Rename/Move/Link (overrides).
6. **Leftovers** section (orphans without ports).
7. Footer: "Check port…", "Find free port…", "Clean up leftovers…", Docker runtime status, last scan time,
   Settings.
- Keyboard: ↑/↓ navigate, ⏎ open, ⌫ stop (with confirmation), ⌘F search, ⌘1–⌘7 filters, ⌘K check/kill port,
  ⌘, Settings, Esc close. Full VoiceOver labels on every control. Respect Reduce Motion, light/dark, and
  increased contrast.
- **NEW badge:** listeners that appeared since the panel was last opened.
- Confirmations are inline in the panel (no modal `NSAlert` that steals focus), except bulk clean-up.

**Global hot key** (Settings, default ⌥⌘P) via Carbon `RegisterEventHotKey` (no Accessibility permission).

**Organise:** hide individual ports or a whole process group (Option-click), show hidden on demand; favorites;
per-port mute (no notifications); monitored port range and excluded ports.

**Notifications** (UserNotifications, each type toggleable, all off by default except watched ports):
watched port started/stopped; watched port taken by something else (conflict); new confirmed orphan; database
exposed to the network; container stopped unexpectedly. Notification actions: Open, Copy address, Stop.

**History** (`~/Library/Application Support/<Brand>/history.jsonl`, configurable retention, default 7 days,
size-capped): port appeared/disappeared events and every stop action (who, what, method, result). Panel:
"History" sheet with filter; Settings: clear history.

**Settings window** (opened from the panel/right-click; SwiftUI `Settings` scene):
- General: launch at login (`SMAppService.mainApp`), status item display, global hot key, appearance follows
  system, language (English first; strings in `Localizable.xcstrings`), daily update check (off by default),
  Uninstall… (removes login item, CLI symlink, support folder, then moves the app to Trash after confirmation).
- Scanning: refresh while closed (2/5/10/30/60 s, default 10), while open (default 2 s), pause on battery /
  Low Power Mode option, monitored range, excluded ports, hide privileged ports (< 1024).
- Ports: hidden ports (tag list; paste comma-separated), favorites, watched ports, muted ports, protected ports.
- Classification: user overrides table; add custom framework matcher (name, match on exe/script/argv, category).
- Orphans: idle threshold, which verdicts show badges, starred list.
- Databases: preferred client per DB type.
- Containers: detected runtimes, manual socket path override.
- Command line & agents: Install/Uninstall CLI (symlink `~/.local/bin/<cli>`; offer `/usr/local/bin` via an
  authorised helper only if the user asks), Enable MCP server, "Allow agents to stop processes" (off by default),
  Copy MCP config snippet for Claude Code / Cursor.
- About: version, licenses, GitHub link.

**Energy behaviour (`SnapshotService`)**
- Timer with ≥ 50% tolerance; pause on `NSWorkspace.willSleepNotification` / screen lock, resume and full
  rescan on wake/unlock; slower cadence on battery or `ProcessInfo.isLowPowerModeEnabled`.
- When closed: socket scan only (no CPU sampling, no HTTP/DB probes, Docker at ≤ 15 s).
- When open: 2 s scans, CPU sampling, probes for visible rows only.
- Diff snapshots; the UI updates only changed rows; no work if nothing changed.
- All scanning on a utility-QoS queue; UI on main actor.

**Accept when:** every feature in this phase is reachable from the status item, keyboard-only use works,
VoiceOver reads every row, and idle CPU with the panel closed averages < 0.1% over 10 minutes
(measure with `top -l` / Activity Monitor and record it in the PR).

---

## Phase 11 — CLI and MCP server (secondary interfaces)

**CLI `ports`** (swift-argument-parser, same `PortsCore`, every command supports `--json`; stable exit codes:
0 ok, 1 not found/port free when expected busy, 2 refused by safety rules, 3 needs confirmation, 4 runtime
error, 64 usage):
- `ports` / `ports list` — `--all`, `--dev`, `--category`, `--project NAME`, `--dir PATH`, `--port N`,
  `--range A-B`, `--since 30m|today`, `--containers`, `--orphans`, `--sort port|uptime|mem|project`,
  `--tcp/--udp` (UDP listing: read-only, Phase 11 adds UDP sockets to the scanner), `--timing`.
- `ports <port>` / `ports explain <port>` — full detail incl. verdict evidence, known-port explanation.
- `ports stop <port|pid…>` — safe ladder; `--force`, `--tree`, `--all-ports`, `--dry-run`, `--yes`
  (never bypasses protected ports or DB warnings).
- `ports free <port…> -- <command…>` — stop then exec the command in the foreground of the user's terminal.
- `ports preflight <port…>` — free? includes bind probe; exit 0 if free.
- `ports next-free [--from 3000]`.
- `ports pause|resume <port|pid>`.
- `ports cmd <port> [--copy]` — print start command.
- `ports open|url <port>`.
- `ports watch [--interval 2s] [--notify]` — headless change stream (NDJSON with `--json`).
- `ports doctor [--fix --yes]` — only safe fixes.
- `ports clean [--dry-run] [--include-likely]` — orphans only.
- `ports history [--since]`.
- `ports mcp` — MCP server over stdio.
- Publish a JSON Schema for `--json` output in `docs/schema/`.

**MCP server** (`ports mcp`, enabled from Settings): tools `list_ports`, `explain_port`, `is_port_free`,
`find_free_port`, `list_orphans`, `project_servers` (servers for a directory), and `stop_port` which is
**disabled unless "Allow agents to stop processes" is on** and even then only stops `safe`-tier processes owned
by the user, never databases, containers, apps or system processes. Every MCP stop is written to history and
shown as a notification.

**Accept when:** `ports list --json | jq` works, exit codes are tested, and the MCP server passes the MCP
inspector's tool listing and a `list_ports` call.

---

## Phase 12 — Distribution and documentation

1. `Scripts/release.sh` + `release.yml` (on tag `v*`): universal build → sign with Developer ID
   (`DEVELOPER_ID_APPLICATION`, secrets for the certificate) → `xcrun notarytool submit --wait` → `stapler
   staple` → zip + DMG → GitHub Release with SHA-256. If signing secrets are missing, produce an unsigned
   build and clearly label it.
2. Homebrew cask template for the owner's tap (`homebrew-tap/Casks/<cli>.rb`): `auto_updates false`,
   `depends_on macos: ">= :sonoma"`, `app`, `binary` for the embedded CLI, `zap` stanza for the support folder
   and preferences, `livecheck` on GitHub releases. Also a source-build formula alternative for users without
   a notarized build. (Official homebrew/cask later requires notarization and notability.)
3. README rewrite: what it is, screenshots/GIF, install (Homebrew tap, DMG, source), feature overview, privacy,
   safety model, CLI & MCP usage, comparison table with credits to the tools that inspired features,
   contributing.
4. `docs/FEATURES.md` checklist fully ticked or each unticked item linked to an issue.

---

## 14. Non-goals (do NOT build these)

Kubernetes port-forward *management* (create/reconnect/logs), starting Cloudflare/ngrok tunnels, VPN status,
firewall rules, fixed `*.localhost` HTTPS addresses / local CA / `/etc/hosts` edits, live page thumbnails and
rendered previews, JSON response previews, scanning other LAN machines or Docker networks, an auto-kill daemon,
in-app restart that spawns servers, dev-stack orchestration (`up`/`down`, project config files, port registry,
auto-restart on crash), Gradle/Kotlin/Flutter daemon cleanup, IDE crash-reporter tweaks, disk-cache cleanup,
caffeinate, self-update command, TUI, local web dashboard, sound effects, hidden-menu-bar-icon warnings,
Windows/Linux builds, a sandboxed App Store build (the sandbox cannot signal other processes).

## 15. Master feature checklist (copy into docs/FEATURES.md)

Phase in brackets. Everything here must be reachable from the menu bar unless marked (CLI).

**Discovery** — TCP listeners with PID [have] · IPv4+IPv6 collapse [have] · IPv6-only detection [have] ·
multi-worker collapse [2] · UDP listeners (CLI list + optional panel filter) [11] · monitored range / excluded
ports [10] · bind probe for invisible owners [5] · configurable refresh / pause [10] · fast-when-open,
slow-when-closed adaptive scanning, sleep/wake/battery aware [10] · known-port hints [3] · DB protocol
detection on non-standard ports [7].

**Classification** — category groups (fixed: no folder-name matching) [1,3] · large framework table [3] ·
confidence score [3] · who-started-it grouping [4] · overrides: rename/move/link/label [3] · app icon/favicon
[3] · safety tiers blocked/warning/safe [3].

**Project context** — project root from manifests incl. monorepos [2] · git branch incl. worktrees [2] ·
filter/act on a project or directory [10,11] · duplicate-instance detection [4].

**Process detail** — command & cwd [have] · memory, CPU, uptime, start time [2] · launcher chain/tree [2] ·
parent column [2] · env names masked (CLI only) [2] · connection count / idle [2] · sort by mem/uptime [10] ·
started-since filter [10,11].

**Orphans & agents** — orphan verdicts with tiers [4] · plain-English evidence + Safe to stop? [4] · safe
exclusions [4] · star/whitelist [4] · leftovers without ports [4] · agent/editor/terminal attribution [4] ·
bulk clean-up with confirmation [4] · Doctor/Health [4] · Copy setup prompt for AI [4].

**Stop & lifecycle** — identity-checked ladder [have, 5] · confirm port freed [1] · wake Ctrl-Z processes [1] ·
DB-safe grace/warning [1] · stop tree / all ports / all workers [5] · supervisor-aware stop (brew services,
launchd, pm2, nodemon, Docker, apps) [5] · multi-select stop [5] · dry run (CLI) [11] · protected ports [5] ·
pause/resume [5] · second-stop escalation [5] · copy start command / run in Terminal [5] · free-then-run (CLI)
[11] · next free port [5].

**Containers** — all runtimes auto-detected [6] · Engine API mapping [6] · image, compose project/service,
health [6] · docker stop not proxy kill [have, 6] · stop compose project [6] · restart container, copy logs
command [6] · 0.0.0.0 publish warning [6].

**Databases** — detection by process/image/protocol [7] · open in auto-detected client [7] · copy connection
string / CLI command [7] · network-exposure warning [7] · safe stop [1,7].

**Tunnels & forwards (display)** — SSH -L/-R/-D [8] · ngrok public URL [8] · cloudflared quick/named [8] ·
kubectl port-forward grouping [8] · gcloud IAP / AWS SSM / cloud-sql-proxy / Tailscale recognised [8].

**Network** — real bind address and exposure [1] · LAN URL + QR [9] · localhost/::1 mismatch diagnosis [4].

**Web** — open in browser with right scheme [1,9] · copy URL/host:port [9] · HTTP status, time, title [9] ·
JSON API badge [9] · web search unknown port [9].

**Interface** — status item count + issue dot [10] · popover with search, filters, sort [10] · keyboard
navigation + VoiceOver [10] · NEW badge [10] · global hot key [10] · light/dark, localisation-ready [10] ·
inline confirmations [10].

**Organise** — hide port/group [10] · favorites [10] · per-port mute [10].

**Notifications** — watched ports start/stop [10] · watched port conflict [10] · new orphan / exposed DB /
container stopped (opt-in) [10].

**History** — port appear/disappear history with retention [10] · stop-action log [10].

**CLI & automation** — list --json [11] · explain [11] · preflight [11] · watch [11] · doctor/clean [11] ·
stable exit codes + JSON schema [11] · CLI embedded and installable from menu bar [10,11] · MCP server with
safe stop gating [11].

**Settings** — launch at login [10] · update check (opt-in) [10] · uninstall [10] · no telemetry [have].

**Distribution** — MIT license & community files [0] · core/app/CLI split, tests, CI [0] · universal binary [0] ·
Developer ID + notarization [12] · Homebrew tap cask + source formula [12] · README & docs [12].
