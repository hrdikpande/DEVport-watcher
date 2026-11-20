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
