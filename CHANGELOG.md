# Changelog

All notable changes to this project will be documented here.

## [Unreleased]

- Added Swift Package Manager structure with shared `PortsCore`.
- Added characterization tests and CI.
- Added initial open-source governance documentation.

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
- Safety tiers: dev servers get 2 s before SIGKILL. Databases and brokers get a
  data-loss warning and 15 s, and are never force-killed automatically; Force
  Quit is a separate, explicit step.
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
  Continuity" or "AirDrop & Handoff") and adds Open AirPlay Settings. System
  owners that launchd restarts (ControlCenter, rapportd, …) are not offered
  Kill.
