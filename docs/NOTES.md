# Roadmap notes

These amendments are recorded for later phases and are intentionally not
implemented in Phase 0.

1. **Release 1 scope:** Release 1 includes Phases 0, 1, 2, 4, 10 (core), and
   Phase 5 limited to process-tree stopping plus Homebrew service and
   LaunchAgent stopping. Release 2 defers database protocol handshakes, QR
   codes, ngrok/cloudflared URL discovery, multi-select cleanup, custom
   classification editing, history analytics, AI setup prompts, and MCP stop.
   *Superseded 2026-11-21 by the owner's decision: build all of Phases 2–12, including every item listed above as deferred.*
2. **Supervisor confirmations:** Every supervisor action confirmation must state
   what will stop, how it will stop, whether it will auto-restart, and whether
   the change persists after login.
3. **Privacy documentation:** Add a Privacy section to Settings and README
   listing every HTTP, database, and Docker-socket probe, when it runs (panel
   open only), where it runs (loopback only), its timeout, and that it is
   read-only.
4. **Panel layout:** Reserve space for container, database, and tunnel badges
   in the Phase 10 row layout from the beginning.
5. **README opening:** README must open with:
   “Ports tells developers what is running locally, why it is running, whether
   it is safe, and how to stop it — without leaving the menu bar.”

## Phase 1 test changes

Only the two `.knownBug` characterization tests changed. Both now assert the
corrected behaviour and no longer carry the tag. Every other Phase 0 test is
unchanged. The `knownBug` tag declaration stays for future use.

- `Known classifier bug: path token is treated as Astro` became
  `Classifier ignores directory names in paths`. `python3 …/astro-dashboard/app.py`
  now expects Backend / `python3` instead of Frontend / `astro`.
- `Known exposure bug: specific LAN bind is not exposed` became
  `Specific LAN bind is network-reachable`. The old test built a `Listener`
  with `exposed: false` and asserted `false`, which the model can no longer
  express. It now builds the listener from a real `192.168.1.20` address and
  expects `.specific("192.168.1.20")` and `exposed == true`.

New Phase 1 tests live in `Tests/PortsCoreTests/Phase1Tests.swift`.

## Found during Phase 1, for later

- `docs/IMPLEMENTATION_PROMPT.md` was still not in the working tree at the
  Phase 1 follow-up, so it has not been committed. `Scripts/dev_harness.sh` was
  built from the Phase 1 item list alone. Check it against the full item 11
  text.
- The AirPlay pane is named "AirDrop & Continuity" from macOS 26 (confirmed on
  Tahoe) and "AirDrop & Handoff" before (Apple's macOS 13 guide). macOS 14 and
  15 are assumed to use the old name and have not been checked on a real Mac.
- `KnownPorts.restartedByLaunchd` is a hand-kept list. Reading the process's
  launchd job (KeepAlive) would be exact; that belongs to the supervisor-aware
  phase.
- The menu bar badge still counts developer kinds only. System processes now
  shown in the Developer view (KnownPorts) are not counted.
- The background poll (every 10 s) reuses the last container map, applied only
  to runtime proxies. If one container is replaced by another on the same port
  behind the same proxy PID, the old name shows until the menu is opened, which
  always re-queries.
- With several runtimes installed, only the first container CLI found is
  queried. Its docker context may point at a different runtime than the one
  that owns the port. The fix is to query per runtime (supervisor-aware phase).
- `/usr/local/bin/podman` (Intel Homebrew) is not in the lookup list. Only the
  paths named in Phase 1 were added.
- Stopping a launchd `KeepAlive`, `brew services` or pm2 process just makes it
  respawn. The post-stop report then shows "Still listening" with a new PID.
  Supervisor-aware stopping is a later phase.
- The web probe reads only the first reply segment, so an nginx "plain HTTP to
  HTTPS port" body split across segments would be read as http.
- `ports list` (CLI) does not show the bind address, Stopped state or web
  scheme yet.
- Row labels append the working-directory name (e.g. `python · my-project`).
  Screenshots shared publicly may want a way to hide it.
- `swift run` inside the harness takes about 10 s per launch. A prebuilt
  binary would be faster, but it can go stale (that happened during Phase 1).
- The web probe never connects to a non-loopback address, so a server bound
  only to a specific LAN IP gets no "Open in Browser". Connecting to the Mac's
  own interface address would never leave the machine, but it would break the
  loopback-only privacy promise. Decide whether to allow it.

## Found during Phase 2

- macOS (confirmed on 26) withholds other processes' environments from
  `KERN_PROCARGS2`, even for your own uid (`ps -E` shows none either).
  `ports list --env` says so instead of printing nothing; the code still masks
  values on systems that return them.
- Memory gate: a plain AppKit status-item app shows ~50 MB RSS because RSS
  counts shared framework pages. Its physical footprint (Activity Monitor's
  "Memory") is ~15 MB. The < 40 MB gate is measured as physical footprint
  (`vmmap --summary`), and RSS is recorded too.
- A Phase 1 build left running for 2 h had grown to a 41 MB footprint. The web
  probe cache was never pruned. Fixed in Phase 2. Phase 10 should add a soak
  measurement.
- Harness scenarios now run from their temp folder, so labels never pick up the
  repo the harness lives in.
- `/bin/sh` reports itself as `bash` in the process table, so launcher chains
  show `bash`.

## Found during Phase 3

- `exePath` rules (Kibana, LM Studio) match where a bundled runtime is
  installed, never the user's working directory or a script's folders. The
  Phase 1 rule against matching folder names still holds.
- Express, Fastify, Hono and Koa can't be seen from argv; they are inferred
  from the project's package.json dependencies, at confidence 60.
- Background services means your own process with launchd as its parent. An
  orphan reparented to launchd looks the same until Phase 4's orphan analyzer
  and Phase 5's launchd lookup tell them apart.
- Overrides are keyed by executable, the tool it runs, and the project root
  (or cwd), so they survive restarts. A port number is not part of the key.
- The Settings table for overrides and custom framework matchers comes with the
  Settings window (Phase 10). For now the row's Customize menu edits overrides.
- ui_smoke reads only top-level menu rows. The Customize submenu was checked by
  build only.

## Found during Phase 4

- Launchd job detection uses `launchctl list` (your user's jobs), through
  `Exec.run`. It runs only when something was adopted by launchd, at most every
  30 s, and only while the menu is open.
- Claude Code's kernel process name is its version number (e.g. `2.1.329`), so
  starters match argv[0], which is readable for your own processes.
- The /usr/bin python3 and perl shims re-exec and drop a fake argv[0]. Harness
  scenarios name tools by script instead.
- An SSH login's tree tops out at a root-owned `sshd`. That isn't adoption, so
  it is never flagged.
- Bind-probe ("invisible owner") and watched-port Doctor issues need Phase 5
  and Phase 10.
- The `--with-launchd` harness scenario is owner-run only. The auto-mode
  classifier blocks the agent from registering LaunchAgents.

## Found during Phase 5

- launchd jobs are found from `launchctl list` (pid → label), not by matching
  plists. `~/Library/LaunchAgents` is read only to say whether a job loads
  again at login and whether it has KeepAlive.
- pm2 is a node script, so `Exec.run` takes a `pathPrefix` (the tool's own
  folder) for it to find node. The rest of the environment stays minimal.
- Multi-select is a checkbox dialog in the NSMenu UI. The Phase 10 panel does
  row multi-select.
- `ports preflight` and `ports next-free` are hand-parsed until the Phase 11
  argument-parser CLI.
- Existing test changed: Phase 1 `WebProbeTests.probe(_:)` passes
  `budget: 5`. Its test server answers from a background thread that can be
  slow under parallel load (it flaked about 1 run in 30). The 0.8 s budget is
  still asserted by "A server that never answers costs about the probe
  budget".

## Found during Phase 6

- Podman socket paths, per the Podman docs: 4.x under
  `~/.local/share/containers/podman/machine/<provider>/podman.sock`, 5.x at
  `$TMPDIR/podman/<machine>-api.sock`. Both are searched. Not checked against
  a real Podman install on this Mac.
- `DOCKER_HOST=tcp://…` is ignored on purpose: Ports only talks to local unix
  sockets.
- The harness's fake proxy is a small C program built with `cc`, because a
  copied Apple binary (`nc`) is killed at launch.
- ui_smoke doesn't check the container row: the fake engine is reached
  through `DOCKER_HOST`, which only the CLI run in the harness sets.
- `engineRestartPolicy` (`GET /containers/<id>/json`) exists, but the stop
  confirmation doesn't show the policy yet. It says "only if its restart
  policy says so". Phase 10's inline confirmation should show the actual
  policy.

## Found during Phase 7

- `ports list --probe` is an explicit, user-invoked form of the open-menu
  probes. Same rules: loopback, read-only, the same budgets. The menu-closed
  rule is about the app, which never probes while its menu is closed.
- A database container is Docker-kind, so the web-probe rule ("never against
  Databases kind") is enforced with `knownDatabase`: process, image or
  handshake.
- Which client opens each scheme is up to macOS (`urlsForApplications`). The
  Settings window (Phase 10) will show and change the remembered client.

## Found during Phase 8

- cloudflared's metrics server serves `/quicktunnel` (`{"hostname": …}`) for
  quick tunnels. Its address is whatever port cloudflared listens on (random
  unless `--metrics` is set). Ports asks the cloudflared row's own listening
  ports. Named tunnels have no public hostname there; their ingress lives in
  `config.yml`, which Ports doesn't read.
- The harness forwarders are a small C listener started with `exec -a
  ssh|kubectl` and their real-looking argv. No real tunnel is opened.
- The loopback HTTP client shares its request code with the unix-socket
  Engine client. It only connects to 127.0.0.1.

## Found during Phase 9

- Settled the Phase 1 question: servers bound only to a LAN IP are never
  probed. They get Copy LAN URL and QR instead (amendment 5).
- The app's WebCache moved into PortsCore as WebProbeCache, so the app and the
  CLI share one probe and one cache policy.
- The TLS probe can't be unit-tested without a certificate identity, so the
  harness covers it (python TLS server: HTTPS · 200). The unit test covers a
  TLS GET to a plain server failing within its deadline.

## Found during Phase 10

- System Events lists the popover but returns no children beneath it. I tried
  three ways: `entire contents`, a recursive `UI elements` walk, and a raw
  AXChildren walk. ui_smoke still checks that the app stays alive and the
  panel opens. Row and badge checks are manual (VoiceOver); ui_smoke exits
  with 78, which check.sh reports as "manual".
- `.transient` popovers closed at once when macOS declined to activate the
  accessory app. The panel uses `.applicationDefined` plus a global click
  monitor and Esc.
- Memory: the SwiftUI panel costs about 25 MB while open and leaves heap
  fragmentation after it closes. The panel is now built on open and released
  on close, icons are kept as 32 px bitmaps, and argv buffers are
  right-sized. Footprint with the harness running is 38.7–40.2 MB against the
  40 MB gate (thin margin); raw RSS is about 116 MB.
- CommandLineTools ship no xcstringstool, so build_app.sh converts the
  xcstrings catalog itself.
- Idle CPU with the panel closed: 0.098 % over 120 s (gate < 0.1 %), with the
  harness's 25 listeners being scanned every 10 s.

## Found during Phase 11

- `ports free … -- <command>` replaces the CLI process with the user's own
  command (`execvp`, foreground, same terminal). This is the one launch that
  isn't a fixed path, by design: it is the user's command, run visibly, never
  by the app.
- Exit codes are tested by running the built `ports` binary from the test
  bundle's folder, with an isolated `PORTS_SUPPORT_DIR`.
- I did not run the MCP Inspector (`npx @modelcontextprotocol/inspector`),
  because it needs a network download. The harness runs an equivalent stdio
  session: initialize, notifications/initialized, tools/list, list_ports, and
  a stop_port that must be refused. A run with the Inspector is listed under
  Owner actions.
- Existing test changed: Phase 6 "Sockets are found in order…" now considers
  only sockets under the test's temporary home. The Mac's real
  `/var/run/docker.sock` (Docker Desktop) made it environment-dependent.
- Universal builds use `-runtime-compatibility-version none`. macOS 14 needs no Swift back-deployment shims, and
  CommandLineTools ship `libswiftCompatibility56.a` for arm64 only, which broke the x86_64 link of
  swift-argument-parser.
- Mid-session, OrbStack took over `/var/run/docker.sock` with 4 containers. Closed-panel scans now run one socket
  scan and apply container labels to it. Engines are asked at most once a minute while closed (the spec's ceiling
  is every 15 s), on every open, and at once when proxy listeners change. The panel list is lazy again. Footprint
  went from 45 MB to 37 MB; idle CPU is 0.055 %.

## Found during Phase 12

- `release.sh` was run locally without secrets: it produced `Ports-1.0.0-unsigned.zip` and `.dmg` (`hdiutil verify`
  OK), SHA-256 sums and release notes. The signed and notarized paths can't be exercised without the owner's
  certificate and notary key.
- The bundle identifier is still `local.portwatch.ports` (Brand.swift), not the spec's suggested
  `io.github.hrdikpande.ports`. Changing it would reset existing users' preferences and the login item, so it
  stays the owner's call (one line in Brand.swift and Info.plist).
- The cask and formula templates need real SHA-256 values and a published tap repository.

## Idle CPU and memory gates (final)

- Memory gate: **physical footprint** (Activity Monitor's "Memory", `vmmap --summary`), budget 40 MB. RSS is
  printed for information only: it counts shared AppKit/SwiftUI framework pages that every app maps, so a bare
  status-item app already shows about 50 MB RSS. Footprint is what the app actually costs the system.
- Leak check (perf_check): the footprint after 20 panel opens must be within 5 MB of the footprint after 3.
  Measured: 36.8 → 38.8 MB with the harness, 33.0 → 34.4 MB without.
- Idle CPU diagnosis (menu closed, 60 s settle, `sample` 10 s, `top -stats pid,cpu,idlew`):
  - At rest, every thread is parked in `mach_msg`, with about 0.4 idle wake-ups/s and 0.15 s of CPU in total.
  - The failing runs (1.5–18 %) had the **panel still open** after perf_check's clicks. Their spike samples were
    open-panel work: `analyze` and Docker queries on 2 s scans.
  - Cause: the outside-click monitor recorded a "closed by outside click" time even when the panel wasn't open,
    so the status item's next open click was swallowed, and the following "close" click opened the panel.
  - Fixed: that time is recorded only when a close really happens.
- Also fixed:
  - The status item's title and image are set only when they change; a fresh dot image was drawn on every scan.
  - The panel model publishes only real diffs; the scan time and container status only while the panel is
    visible.
  - perf_check now verifies that the panel is closed before measuring idle CPU, and fails if it isn't.
- Checked, nothing to change:
  - The timer returns to the closed cadence on close (`popoverDidClose` → `reschedule`), with tolerance ≥ 50 %.
  - No ProcessInfo activity or power assertion is held, so App Nap works.
  - No probes, CPU sampling or database handshakes run while closed. Docker is asked at most once a minute
    while closed.
- Idle CPU (menu closed, 120 s, `top` average): 0.058 % with the harness running; 0.034–0.144 % without it
  (the 0.144 % run was one of four). Steady state is about 0.07 %. The first 10 s after closing include the
  SwiftUI teardown.
- **Idle CPU measurement changed (decided before the next gate run, not after a failure).** The gate is now the
  app's own CPU time (user + system, `ps -o cputime=`) read at the start and end of each 120 s closed-panel window:
  idle % = CPU-time delta / 120 s. Three windows; the gate is the median, against the same 0.1 % budget.
  - Why: `top` prints CPU per sample with one decimal (0.0, 0.3 …), so near 0.1 % a single scan landing inside a
    1 s sample decided the result. That is how the same build read 0.034 % and 0.144 % on consecutive runs.
  - CPU time is cumulative and exact to 10 ms, so the window total doesn't depend on when samples happen. The
    median of three windows keeps one burst (such as the teardown just after the panel closes) from deciding the
    gate alone.
- **Closed-panel scan cost (the real idle CPU bug).** After the UI work, the gate's windows read 0.1–0.2 % with
  0.01 s of CPU per 10 s scan.
  - Profile (`sample`, 40 s at 1 ms): two thirds of the scan time was `Proc.sockets`, which walks the file
    descriptors of all ~730 processes on every tick.
  - Fix: on closed-panel scans, a process that had no listening socket at its last check is re-checked every
    30 s; listeners and new PIDs are still checked every scan. Open-panel scans, full refreshes and the CLI check
    every process.
  - Known limit (commented as a shortcut in ProcessCache): a long-running process that starts listening later,
    or a new process reusing a quiet PID, appears in the closed-panel count within 30 s. It appears at once when
    the panel opens.
  - Result: 6 minutes idle = 0.30–0.36 s of CPU (about 0.08–0.1 %) on this Mac.
- One gate window read 3.367 % (median 0.058 %). It did not reproduce in 2 × 6 minutes of watching with a burst
  sampler, before or after 20 panel cycles. It was most likely caused by activity elsewhere on the Mac (for
  example many ports changing at once). The median of three windows is meant for exactly this; a failing median
  is treated as a bug.
- **Docker CLI respawning (the idle CPU bug with the harness).** With the harness running, the median was
  0.18–0.23 %. The harness's fake `gvproxy` makes Ports look up containers. No engine socket answered, so every
  closed-panel lookup (once a minute) spawned the `docker` CLI fallback, which failed. Fix: when nothing answered
  last time, closed-panel lookups wait 10 minutes; an open panel always asks again. Median after the fix: 0.058 %
  (windows 0.009 · 0.058 · 0.083).
- **Panel state in scripts.** Once the panel's view was built only on open (the memory fix), System Events
  stopped reporting the popover as a child of the status item. ui_smoke then said "did not open", and
  perf_check's "is it closed?" check could pass while the panel was still open.
  - Fix: both scripts read the app's on-screen windows from Quartz (`Scripts/panel_windows.swift`, a window
    list only, no screenshots). The panel is open when a window taller than 300 pt exists.

