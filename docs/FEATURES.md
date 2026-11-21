# Feature checklist

The full list from spec §15. The phase is in brackets. Everything is reachable from the menu bar unless
marked (CLI). A ticked item is implemented and tested. An item that can't be finished without the owner says why.

## Discovery
- [x] TCP listeners with PID [have]
- [x] IPv4 + IPv6 collapse [have, 1]
- [x] IPv6-only detection [have]
- [x] Multi-worker collapse [2]
- [ ] UDP listeners (CLI list + optional panel filter) [11]
- [ ] Monitored range / excluded ports [10]
- [x] Bind probe for invisible owners (Check Port…, `ports preflight`) [5]
- [ ] Configurable refresh / pause [10]
- [ ] Adaptive scanning: fast when open, slow when closed; sleep, wake and battery aware [10]
- [x] Known-port hints [3]
- [ ] DB protocol detection on non-standard ports [7]

## Classification
- [x] Category groups, without folder-name matching [1, 3]
- [x] Large framework table [3]
- [x] Confidence score [3]
- [x] Who-started-it attribution [4]
- [ ] Group rows by who started them [10]
- [x] Overrides: rename, move, link, label/note, favorite, hide, mute [3]
- [x] App icon / project favicon [3]
- [x] Safety tiers: blocked, warning, safe [3]

## Project context
- [x] Project root from manifests, incl. monorepos [2]
- [x] Git branch, incl. worktrees [2]
- [ ] Filter / act on a project or directory [10, 11]
- [x] Duplicate-instance detection [4]

## Process detail
- [x] Command and cwd [have]
- [x] Memory, CPU, uptime, start time [2]
- [x] Launcher chain / tree [2]
- [x] Parent column [2]
- [x] Env names with secret values masked (CLI) [2]; macOS 26 withholds other processes' environments, so the CLI says so
- [x] Connection count / idle [2]
- [ ] Sort by memory / uptime [10]
- [ ] Started-since filter [10, 11]

## Orphans & agents
- [x] Orphan verdicts with tiers [4]
- [x] Plain-English evidence + Safe to stop? [4]
- [x] Safe exclusions [4]
- [x] Star / whitelist [4]
- [x] Leftovers without ports [4]
- [x] Agent / editor / terminal attribution [4]
- [x] Bulk clean-up with confirmation [4]
- [x] Doctor / Health [4]
- [x] Copy setup prompt for AI [4]

## Stop & lifecycle
- [x] Identity-checked ladder [have, 5]
- [x] Confirm the port is freed [1]
- [x] Wake Ctrl-Z processes [1]
- [x] DB-safe grace and warning [1]
- [x] Stop tree / all ports / all workers [5]
- [x] Supervisor-aware stop: brew services, launchd, pm2, nodemon, Docker, apps [5]
- [x] Multi-select stop (Stop Several…; panel multi-select in [10]) [5]
- [ ] Dry run (CLI) [11]
- [x] Protected ports (type the number to stop) [5]
- [x] Pause / resume [5]
- [x] Second-stop escalation (Force offered within 2 min) [5]
- [x] Copy start command / Run in Terminal [2, 5]
- [ ] Free-then-run (CLI) [11]
- [x] Next free port (Find Free Port…, `ports next-free`) [5]

## Containers
- [x] All runtimes auto-detected [6]
- [x] Engine API mapping [6]
- [x] Image, compose project/service, health [6]
- [x] `docker stop`, not a proxy kill [have, 6]
- [x] Stop compose project [6]
- [x] Restart container, copy logs command [6]
- [x] 0.0.0.0 publish warning [6]

## Databases
- [ ] Detection by process / image / protocol [7]
- [ ] Open in auto-detected client [7]
- [ ] Copy connection string / CLI command [7]
- [ ] Network-exposure warning [7]
- [ ] Safe stop (brew services for brew DBs) [1, 7]

## Tunnels & forwards (display)
- [ ] SSH -L/-R/-D [8]
- [ ] ngrok public URL [8]
- [ ] cloudflared quick/named [8]
- [ ] kubectl port-forward grouping [8]
- [ ] gcloud IAP / AWS SSM / cloud-sql-proxy / Tailscale recognised [8]

## Network
- [x] Real bind address and exposure [1]
- [ ] LAN URL + QR [9]
- [x] localhost / ::1 mismatch diagnosis [4]

## Web
- [ ] Open in browser with the right scheme [1, 9]
- [ ] Copy URL / host:port [9]
- [ ] HTTP status, time, title [9]
- [ ] JSON API badge [9]
- [ ] Web search for an unknown port [9]

## Interface
- [ ] Status item count + issue dot [10]
- [ ] Popover with search, filters, sort [10]
- [ ] Keyboard navigation + VoiceOver [10]
- [ ] NEW badge [10]
- [ ] Global hot key [10]
- [ ] Light/dark, localisation-ready [10]
- [ ] Inline confirmations [10]

## Organise
- [ ] Hide a port / a process group [10] (hiding one row: done in [3])
- [x] Favorites [3]
- [ ] Per-port mute (notifications) [10] (stored since [3])

## Notifications
- [ ] Watched ports start / stop [10]
- [ ] Watched port conflict [10]
- [ ] New orphan / exposed DB / container stopped (opt-in) [10]

## History
- [ ] Port appear/disappear history with retention [10]
- [ ] Stop-action log [10]

## CLI & automation
- [ ] `list --json` [11]
- [ ] `explain` [11]
- [ ] `preflight` [11] (basic form since [5])
- [ ] `watch` [11]
- [ ] `doctor` / `clean` [11]
- [ ] Stable exit codes + JSON schema [11]
- [ ] CLI embedded and installable from the menu bar [10, 11]
- [ ] MCP server with safe-stop gating [11]

## Settings
- [ ] Launch at login [10]
- [ ] Update check (opt-in) [10]
- [ ] Uninstall [10]
- [x] No telemetry [have]

## Distribution
- [x] MIT license and community files [0]
- [x] Core/app/CLI split, tests, CI [0]
- [x] Universal binary [0]
- [ ] Developer ID + notarization [12]
- [ ] Homebrew tap cask + source formula [12]
- [ ] README and docs [12]
