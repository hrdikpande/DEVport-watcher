# Feature checklist

This is the Phase 0 baseline and forward-looking feature checklist. Items
marked `have` describe current behavior; numbered items are planned phases.

## Discovery

- [x] TCP listeners with PID (have)
- [x] IPv4/IPv6 listener discovery (have)
- [x] IPv4/IPv6 collapse (1)
- [ ] UDP listeners (11)
- [ ] Monitored ranges and excluded ports (10)
- [ ] Bind probe for invisible owners (5)
- [ ] Configurable refresh and pause (10)
- [ ] Adaptive sleep, wake, battery, and Low Power Mode scanning (10)
- [x] Known-port hints (3)
- [ ] Database detection on non-standard ports (7)

## Classification and project context

- [x] Category model: Frontend, Backend, Databases, Containers, Tunnels & forwards, AI & agents, Background services, Apps, System (1, 3)
- [x] Tool classification table (have)
- [x] Large data-driven framework table (3)
- [x] Confidence scores and safety tiers (3)
- [x] Project root, monorepo, and Git branch detection incl. worktrees (2)
- [ ] Launcher, editor, terminal, and coding-agent attribution (4)
- [ ] Duplicate-instance detection (4)
- [x] User classification overrides: rename, move, link, note, favorite, hide, mute (3; Settings table in 10)
- [x] Application icons and project favicons (3)

## Process details and cleanup

- [x] Command line and working directory (have)
- [x] PID identity and owner checks (have)
- [x] CPU, memory, uptime, parent, and connection metrics (2)
- [x] Launcher chain (parent → … → launchd), process group, controlling TTY (2)
- [x] Multi-worker collapse into one row with a worker count (2)
- [x] Environment names with secret values masked, CLI only (`ports list --env`) (2)
- [ ] Process tree and supervisor-aware stopping (5)
- [ ] Orphan verdicts and leftovers without ports (4)
- [ ] Bulk cleanup with confirmation (4)
- [ ] Health/Doctor section (4)
- [x] Copy start command (2)
- [ ] Run in Terminal (5)

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
