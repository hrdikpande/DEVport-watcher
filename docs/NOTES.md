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
