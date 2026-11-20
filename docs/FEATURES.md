# Feature checklist

This is the Phase 0 baseline and forward-looking feature checklist. Items
marked `have` describe current behavior; numbered items are planned phases.

## Discovery

- [x] TCP listeners with PID (have)
- [x] IPv4/IPv6 listener discovery (have)
- [ ] IPv4/IPv6 collapse (1)
- [ ] UDP listeners (11)
- [ ] Monitored ranges and excluded ports (10)
- [ ] Bind probe for invisible owners (5)
- [ ] Configurable refresh and pause (10)
- [ ] Adaptive sleep, wake, battery, and Low Power Mode scanning (10)
- [ ] Known-port hints (3)
- [ ] Database detection on non-standard ports (7)

## Classification and project context

- [x] Frontend, backend, database, Docker, and System & Apps groups (have)
- [x] Tool classification table (have)
- [ ] Large data-driven framework table (3)
- [ ] Confidence scores and safety tiers (3)
- [ ] Project root, monorepo, and Git branch detection (2)
- [ ] Launcher, editor, terminal, and coding-agent attribution (4)
- [ ] Duplicate-instance detection (4)
- [ ] User classification overrides (3)
- [ ] Application icons and project favicons (3)

## Process details and cleanup

- [x] Command line and working directory (have)
- [x] PID identity and owner checks (have)
- [ ] CPU, memory, uptime, parent, and connection metrics (2)
- [ ] Process tree and supervisor-aware stopping (5)
- [ ] Orphan verdicts and leftovers without ports (4)
- [ ] Bulk cleanup with confirmation (4)
- [ ] Health/Doctor section (4)
- [ ] Copy start command and run in Terminal (5)

## Containers and databases

- [x] Docker Desktop port mapping and container stop (have)
- [ ] OrbStack, Colima, Lima, Podman, and Rancher detection (6)
- [ ] Container image, Compose, and health details (6)
- [ ] Restart container and stop Compose project (6)
- [ ] Database client actions and connection strings (7)
- [ ] Network-exposure warnings for databases (7)

## Network and web

- [x] Local versus network exposure indicator (have)
- [ ] Real bind address and exposure explanation (1)
- [ ] SSH, Kubernetes, ngrok, cloudflared, and other forwarding detection (8)
- [ ] HTTP status, timing, title, and scheme detection (9)
- [ ] LAN URLs and QR codes (9)

## Interface and organization

- [x] Menu-bar status item and developer count (have)
- [x] Developer/System/All filters (have)
- [ ] Searchable popover with sorting and filter chips (10)
- [ ] Keyboard navigation and VoiceOver support (10)
- [ ] Favorites, hidden ports, and muted ports (10)
- [ ] Notifications and history (10)
- [ ] Settings window and launch-at-login option (10)

## CLI and distribution

- [x] `Ports --list` diagnostic output (have)
- [x] `ports list` command (Phase 0)
- [ ] JSON output, stable exit codes, preflight, watch, doctor, and clean (11)
- [ ] MCP server with safe-stop gating (11)
- [ ] Universal binary and notarized release (12)
- [x] Swift package, tests, CI, and governance files (Phase 0)
