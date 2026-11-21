# Ports

Ports tells developers what is running locally, why it is running, whether it is safe, and how to stop it — without leaving the menu bar.

A native macOS 14+ menu bar app (universal: Apple Silicon and Intel). It finds every listening port, names the
dev server, database, container or tunnel behind it, says which project, branch and coding agent started it,
flags orphans and leftovers, and stops things the safe way: through their supervisor when they have one, with an
identity check before every signal. A CLI and an MCP server expose the same core to scripts and coding agents.

> Screenshots and a short GIF go in `docs/images/` (to be added by the maintainer).

## The problem it solves

Local development leaves a lot running: dev servers, databases, containers, watchers, tunnels, and more and more
servers started by AI coding agents. macOS gives you poor tools to see them:

- **"Port 3000 is already in use"**: you need `lsof -nP -iTCP:3000 -sTCP:LISTEN` to find the owner, and
  Activity Monitor doesn't show ports at all.
- **"What *is* this?"**: `node` or `python3` with a PID tells you nothing about which project, branch or tool
  it is, or who started it.
- **"Can I kill it?"**: `kill -9` on a database can lose data. Killing a brew service, LaunchAgent, pm2 app or
  nodemon child makes it come straight back. Killing ControlCenter on port 5000 (AirPlay Receiver) frees
  nothing.
- **"Why is my laptop slow?"**: orphaned dev servers and watchers pile up after terminals close and agents
  finish.
- **"Is this exposed?"**: a database bound to `0.0.0.0`, a container published on all interfaces, or a forgotten
  ngrok tunnel is reachable from your network or the internet without you noticing.

Ports answers all of these from the menu bar: what is listening, what it is, who started it, whether it is safe
to stop, and how to stop it so it stays stopped.

## An open-source alternative to

Ports replaces a mix of command-line habits and single-purpose apps with one native, local-only, MIT-licensed
tool:

| What people use today | What it does | What Ports adds |
|---|---|---|
| `lsof`, `netstat`, Activity Monitor | Raw sockets and PIDs (Activity Monitor has no port view) | Names the framework, project, branch, container and starter; one click to act |
| [`kill-port`](https://www.npmjs.com/package/kill-port) (npm) | Kills whatever is on a port, using `lsof` + an immediate kill | A safe ladder (SIGTERM first, data-store grace periods), supervisor-aware stops, a port-freed check |
| [`fkill-cli`](https://www.npmjs.com/package/fkill-cli) | Interactive, cross-platform process killer (`fkill :8080`) | Port context, orphan verdicts, protected ports, JSON output and exit codes for scripts |
| PortKiller-style menu bar apps (for example [jamiepine/port-killer](https://github.com/jamiepine/port-killer), [gupsammy/PortKiller](https://github.com/gupsammy/PortKiller), [CedricEugeni/portkiller](https://github.com/CedricEugeni/portkiller)) and paid ones such as [portkill.app](https://www.portkill.app/) | List listening ports and kill the owner; some add Docker or brew integration | Orphan and leftover detection with evidence, coding-agent attribution, database handshakes, tunnel public URLs, Doctor, a CLI and an MCP server |
| Port viewers such as [ChaosCoder/Ports](https://github.com/ChaosCoder/Ports), [Portsly](https://github.com/ghinkle/portsly), [PortTray](https://github.com/Koushith/porttray), [Portero](https://porteroapp.pages.dev/) | Show which app listens on which port, some with project grouping | A safety model end to end, exposure warnings, every container runtime, history and notifications |

Ports is not a firewall, a tunnel manager, a Kubernetes client or a process supervisor. Those tools do their jobs
well, and Ports only shows what they are doing.

> Naming note: an older open-source utility is also called "Ports" (ChaosCoder/Ports). The name lives in one file
> (`Sources/PortsCore/Brand.swift`), so this project can be renamed easily.

## Install

| How | Command |
|---|---|
| Homebrew cask (notarized releases) | `brew install --cask hrdikpande/tap/ports` |
| Homebrew from source | `brew install hrdikpande/tap/ports` (builds the CLI and the app with Xcode) |
| DMG / zip | Download from [Releases](https://github.com/hrdikpande/DEVport-watcher/releases), drag Ports.app to Applications |
| From source | `./Scripts/build_app.sh` (builds a universal `build/Ports.app` and copies it to `~/Applications`) |

Builds without a Developer ID are labelled **unsigned** in their file name and release notes. Open them once with
right-click → Open (or remove the quarantine attribute after checking the SHA-256).

The CLI ships inside the app (`Ports.app/Contents/Helpers/ports`). Settings › Command Line & Agents links it to
`~/.local/bin/ports`.

## What it shows

- **Every listener**: port, PID, real bind address and whether it is reachable from your network (LAN badge),
  IPv4/IPv6 owners, prefork workers grouped (`×3`), UDP sockets (CLI).
- **What it is**: a data-driven table of 120+ frameworks, from Vite and Next.js to Django, Rails, Spring and Phoenix,
  plus databases, brokers, tunnels and model servers. Each row gets a category, a confidence score and a safety
  tier. Directory names are never used to guess.
- **Where it comes from**: project (from manifests, monorepos as `repo › package`) and git branch (read from
  `.git`, worktrees included), launcher chain, and who started it (Claude Code, Cursor, Codex, VS Code, iTerm2,
  tmux, pm2, a launchd job…).
- **Health**: orphan verdicts with plain-English evidence and a *Safe to stop?* answer, duplicate instances,
  leftovers without ports (`tsc -w`, MCP servers), databases exposed to the network, containers published on
  0.0.0.0, `localhost` vs `127.0.0.1`/`::1` mismatches, ports held by processes macOS doesn't show.
- **Containers** (Docker Desktop, OrbStack, Colima, Lima, Rancher Desktop, Podman) via each engine's local socket:
  container, image, compose project/service and health; stop, restart, stop the whole compose project, copy the
  logs command.
- **Databases**: recognised by process, image or a read-only handshake. Open in your database client, or copy the
  connection URL or `psql`/`mysql`/`redis-cli`/`mongosh` command.
- **Tunnels and forwards** (shown, never managed): `ssh -L/-R/-D`, kubectl port-forward, ngrok and cloudflared
  public URLs, gcloud IAP, AWS SSM, cloud-sql-proxy, Tailscale.
- **Web**: status, response time and page title, a JSON API badge, Open in Browser with the right scheme, Copy
  URL / LAN URL, and a QR code for your phone.

## Features in detail

Each feature lists what it does, who uses it, and why it helps.

### Live port list
- **What:** every listening TCP port with its process, PID, bind address and uptime. Worker processes are grouped
  into one row (`×3`). The CLI also lists UDP sockets (`ports list --udp`).
- **Who:** anyone who has seen `EADDRINUSE` or "port 3000 is already in use".
- **Why:** you see the owner of a port in one click, without `lsof -i :3000 | grep LISTEN`.

### Framework detection
- **What:** names 120+ dev servers, frameworks, databases, brokers, tunnels and model servers from the executable,
  the script and the command, never from folder names. Each row carries a confidence score and a safety tier.
- **Who:** frontend, backend and full-stack developers juggling Vite, Next.js, Django, Rails, Spring, Phoenix and
  others at once.
- **Why:** "node (PID 48213)" becomes "Next.js · shop › web · main".

### Project and branch
- **What:** walks up to the nearest manifest (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, …), shows
  monorepo packages as `repo › package`, and reads the git branch straight from `.git` (worktrees included).
- **Who:** monorepo teams and anyone running the same app on several branches or worktrees.
- **Why:** you know which checkout is answering on a port before you debug the wrong one.

### Who started it
- **What:** the launcher chain and the first meaningful starter: a coding agent (Claude Code, Cursor, Codex,
  Gemini, Aider, …), an editor, a terminal, tmux, pm2 or a launchd job.
- **Who:** developers who let coding agents start servers, and tech leads reviewing what an agent left running.
- **Why:** servers an agent started don't stay anonymous.

### Orphans, leftovers and duplicates
- **What:**
  - Verdicts of confirmed, likely and possible orphans, each with plain-English evidence and a *Safe to stop?*
    answer.
  - Leftover watchers and MCP servers that hold no port.
  - "Running twice" detection.
  - Bulk clean-up that always lists exactly what will be signalled.
- **Who:** anyone whose laptop slows down after a week of `npm run dev`, and agent-heavy workflows.
- **Why:** you get memory and ports back without killing something that's still in use.

### Safe stopping
- **What:** stops through the supervisor:
  - brew services, LaunchAgents, pm2, nodemon, containers, and apps (quit like ⌘Q)
  - a SIGTERM ladder, and SIGKILL only for dev servers
  - pause and resume, protected ports, stop a whole tree or all workers, and Force only as a separate step
- **Who:** everyone, but especially people with local databases holding work they care about.
- **Why:** the confirmation states what stops, how, and whether it comes back, so nothing restarts behind your
  back and nothing loses data by surprise.

### Containers
- **What:** reads Docker Desktop, OrbStack, Colima, Lima, Rancher Desktop and Podman through each engine's local
  socket. Shows container, image, compose project and health. Stops, restarts or stops a whole compose project, and
  copies the logs command.
- **Who:** backend and platform engineers running compose stacks.
- **Why:** "com.docker.backend on 5432" becomes "db-1 · postgres:16 · shop/db · healthy". It also warns when a
  container is published on 0.0.0.0.

### Databases
- **What:** recognises PostgreSQL, MySQL, Redis, MongoDB, Memcached and RabbitMQ by process, image or a read-only
  handshake. Opens the database in your client, copies the connection URL or the `psql`/`redis-cli` command, and
  warns when a database is exposed to the network.
- **Who:** data engineers, backend developers, and anyone with three Postgres versions installed.
- **Why:** you reach the right database fast, and you hear about it when one listens on your café's Wi-Fi.

### Tunnels and forwards
- **What:** shows `ssh -L/-R/-D` forwards, kubectl port-forward, ngrok and cloudflared public URLs, gcloud IAP,
  AWS SSM, cloud-sql-proxy and Tailscale. Display only.
- **Who:** DevOps and SRE engineers, and anyone demoing a local app through a tunnel.
- **Why:** you can tell which local port is on the public internet right now.

### Web details
- **What:** HTTP status, response time and page title; a JSON API badge; Open in Browser with the right scheme;
  Copy URL and LAN URL; a QR code for your phone.
- **Who:** frontend and mobile developers testing on real devices.
- **Why:** scan a QR code instead of typing `192.168.1.23:5173` on a phone keyboard.

### Health (Doctor)
- **What:** a short list of what needs attention, with one-click fixes where they're safe: orphans, duplicates,
  exposed databases, suspended or idle servers, an engine that isn't answering, `localhost` vs `127.0.0.1`
  mismatches, and ports held by processes macOS doesn't show.
- **Who:** everyone, especially new team members setting up a project.
- **Why:** it turns "why can't I connect?" into a one-line answer.

### Notifications and history
- **What:** alerts for watched ports (started, stopped, taken by something else) and, opt-in, for orphans, exposed
  databases and containers that stop. A 7-day history of ports and stop actions.
- **Who:** people who keep a few long-running services up all day.
- **Why:** you learn your API died before your frontend starts throwing errors.

### CLI and MCP server
- **What:** `ports` with every command in `--json`, stable exit codes, `preflight`, `free -- <cmd>` and `watch`.
  `ports mcp` lets coding agents ask about ports; stopping through it is off by default.
- **Who:** scripters, CI pipelines, dotfile tinkerers, and AI coding agents.
- **Why:** `ports preflight 3000 && npm run dev`, and agents that check a port is free before they start a server.

## Who it's for

| You are… | Ports helps you… |
|---|---|
| A frontend developer | find which Vite/Next.js server is on which port, open it, and test it on your phone with a QR code |
| A backend or full-stack developer | see APIs, workers, databases and brokers together, with their project and branch |
| A data or ML engineer | find Jupyter, Streamlit, Gradio, Ollama and databases, and stop them without losing data |
| A DevOps or platform engineer | map container ports to compose services and spot 0.0.0.0 exposure and live tunnels |
| A mobile developer | reach Metro/Expo and local APIs from devices on your network |
| Someone who works with AI coding agents | see what an agent started, clean up what it left behind, and give it safe read-only tools |
| A security-minded developer | find databases and services reachable from your network, and every public tunnel |
| A student or newcomer | understand what "address already in use" means and fix it safely |
| A team lead or educator | standardise a safe way to inspect and stop local services |

## The menu bar

Click the icon for the panel; right-click for Refresh, Pause Scanning, Settings and Quit. The panel's header has
search, a Quit button (⌘Q) and the sort/view menu. Settings is a window with a sidebar of sections, like System
Settings. The global hot key is ⌥⌘P.

- **Search and filters**: search (`/` or ⌘F) and filter chips Developer, All, Favorites, Leftovers, Containers,
  Databases and Tunnels (⌘1–⌘7).
- **Sort**: by category, port, project, uptime, memory or "Started by".
- **Rows**: Health at the top, then Favorites, categories and Leftovers. ↑/↓ moves, ⏎ expands a row with every
  detail and action, ⌫ stops it (with confirmation), ⌘-click selects several, Option-click hides a process group.
- **Organise**: rename, move, link to an app, note, favorite, hide, mute, star (never flag), watch and protect ports.
- **Notifications** for watched ports (started, stopped, taken by something else) and, opt-in, new orphans,
  exposed databases and containers stopping. History keeps 7 days of port and stop events.
- **Everyday use**: VoiceOver labels on every control, light/dark/increased contrast, Reduce Motion, launch at
  login, Uninstall….

## Safety model

- **Nothing is killed automatically.** Every stop asks first, and the confirmation states what will stop, how,
  whether it will restart automatically, and whether the change persists after the next login.
- **Your own processes only**: never PID 0/1, launchd, Ports itself, or another user's processes. Before every
  signal, Ports re-checks the PID and its start time, so a reused PID is never hit.
- **The ladder**: SIGTERM (plus SIGCONT if the process is suspended), then a wait.
  - Only Frontend/Backend dev servers are force-killed (SIGKILL), after 2 s.
  - Apps, services and the container engine get 5 s and are never force-killed automatically.
  - Databases and brokers get a data-loss warning and 15 s, and are never force-killed automatically.
  - Force Quit is always a separate, explicit step.
- **Supervisor-aware**: brew services stop through `brew services`, your LaunchAgents through
  `launchctl bootout`, pm2 apps through `pm2 stop`, nodemon by stopping the watcher, containers through the engine,
  and apps quit like ⌘Q. System processes that launchd restarts (AirPlay Receiver on 5000/7000…) get an
  explanation and a settings link, never a Kill.
- **Other guards**: protected ports need their number typed in. Only one stop flow runs per process. Bulk clean-up
  lists exactly what will be signalled.
- **One code path**: the app, the CLI, the MCP server and bulk clean-up all stop through the same core.
- **Commands it runs**: fixed absolute paths, argument arrays, no shell, a minimal environment and a timeout.

## Privacy

No telemetry, no account, no analytics. Everything Ports probes is listed here (and in Settings › Privacy). Every
probe is read-only.

| Probe | When | Where | Timeout | What it does |
|---|---|---|---|---|
| HTTP probe | Only while the panel is open (or with `ports list --probe`) | 127.0.0.1 and ::1 only. Never servers bound only to a LAN address, never databases or tunnels | 0.8 s per listener, at most 4 at once, re-probed after 30 s | Read-only: HEAD / to detect HTTP, then one GET / (first 64 KB) for status, time, Server header and <title>. |
| TLS hello | Same as the HTTP probe, when a server doesn't answer plain HTTP | 127.0.0.1 and ::1 only | Within the same 0.8 s | Read-only: a minimal TLS ClientHello and, for HTTPS servers, one GET /. Self-signed certificates are accepted for this probe only. |
| Database handshake | Only while the panel is open (or with `ports list --probe`) | Loopback only, only your own listeners above port 1023 that aren't already known as databases | 300 ms per handshake, 0.8 s per listener | Read-only: PostgreSQL SSLRequest, MySQL greeting, Redis PING, MongoDB hello, Memcached version, AMQP header. Never sends credentials. |
| Docker Engine socket | Only while a container runtime's port proxy is listening: on every panel open, at most every 15 s otherwise | Local unix sockets of Docker Desktop, OrbStack, Colima, Lima, Rancher Desktop, Podman (never DOCKER_HOST=tcp://) | 2 s | Read-only GET /containers/json. Containers are stopped or restarted only when you confirm it. |
| ngrok agent API | Only while the panel is open (or with `ports list --probe`) | 127.0.0.1, on the ngrok agent's own port | 0.8 s | Read-only GET /api/tunnels for public URLs. |
| cloudflared metrics | Only while the panel is open (or with `ports list --probe`) | 127.0.0.1, on cloudflared's own metrics port | 0.8 s | Read-only GET /quicktunnel for a quick tunnel's hostname. |
| Bind probe | Only when you use Check Port…, Find Free Port…, `ports preflight` or `ports next-free` | This Mac: 127.0.0.1, ::1, 0.0.0.0 | Immediate | Binds the port without listening and closes it at once. No traffic is sent. |
| Local commands | launchctl list while the panel is open; brew services / launchctl bootout / pm2 / docker only when you confirm a stop | This Mac (fixed paths, no shell, minimal environment) | 2–30 s | Read-only except the stop you confirmed. |
| Update check (off by default) | Once a day, only if you turn it on in Settings › General | api.github.com (the project's latest release) | 10 s | The only request Ports ever makes to the internet. Nothing about your Mac is sent. |

## Command line

```
ports                          # the Developer view (same as `ports list`)
ports list --all --json        # every listener as JSON (schema: docs/schema/ports-list.schema.json)
ports list --project shop --since 2h --sort mem
ports 3000                     # explain port 3000: owner, who started it, verdict and evidence
ports stop 3000 --dry-run      # show the plan (supervisor, signals) without doing anything
ports stop 3000 --yes          # stop it (protected ports and databases still need you)
ports free 3000 -- npm run dev # free the port, then run the command in this terminal
ports preflight 5173           # exit 0 if free (bind probe included)
ports next-free --from 3000
ports watch --json             # NDJSON stream of ports appearing/disappearing
ports doctor | ports clean --dry-run | ports history --since today
```

Exit codes: `0` ok · `1` not found or port busy · `2` refused by the safety rules · `3` needs confirmation ·
`4` runtime error · `64` usage.

## MCP server (coding agents)

Enable it in Settings › Command Line & Agents, then add it to your agent, for example:

```json
{ "mcpServers": { "ports": { "command": "~/.local/bin/ports", "args": ["mcp"] } } }
```

- **Tools**: `list_ports`, `explain_port`, `is_port_free`, `find_free_port`, `list_orphans`, `project_servers`
  and `stop_port`.
- **`stop_port` is off by default.** It works only when you turn on "Allow agents to stop processes", and even then
  only for your own dev servers: never databases, containers, apps, services, system processes or protected ports.
- **Visibility**: every agent stop is written to History and shown as a notification.

## How it compares (credits)

Ports combines ideas from these tools; thank you to their authors.

| Tool | Idea Ports borrows |
|---|---|
| PortKiller | One-click stop from the menu bar |
| LeftOpen | Finding servers you forgot to close |
| Portreaper, devclean | Orphan and leftover clean-up |
| Portpourri, Porthole, Seeports | A readable list of local servers with context |
| portctl (Rust and Python), ports-cli | A scriptable CLI with JSON output |
| Portolan, Bosun | Project and container awareness |

What Ports adds: supervisor-aware stopping with four-part confirmations; orphan verdicts with evidence; coding-agent
attribution; containers through every runtime's own socket; database handshakes; and an MCP server whose stop is gated.

Ports deliberately doesn't manage tunnels or Kubernetes, start servers, edit `/etc/hosts`, or kill anything on its
own (see `docs/IMPLEMENTATION_PROMPT.md` §14).

## Contributing: help build it

Ports is open source and we'd love your help. Good first contributions:

- **Teach it a new tool:** add a row to `Sources/PortsCore/Detect/Frameworks.swift`. The test suite covers it
  automatically.
- **Add a coding agent, editor or terminal:** add it to `Sources/PortsCore/Detect/AgentDetector.swift`.
- **Support another container runtime or database protocol:** add the socket path or the read-only handshake.
- **Translate the app:** `Localization/Localizable.xcstrings`.
- **Improve accessibility, docs and screenshots:** VoiceOver, keyboard flows, and the README images.
- **Report a misclassification:** open an issue with the output of `ports explain <port> --json`, with personal
  paths removed.

Start with [CONTRIBUTING.md](CONTRIBUTING.md); run `./Scripts/check.sh` before opening a pull request. Every
contribution, from a typo fix to a new detector, makes local development calmer for everyone. Thank you!

## Building

```
swift build && swift test       # PortsCore, the app and the CLI
./Scripts/build_app.sh          # universal app bundle (add --no-install to only build)
./Scripts/check.sh              # every gate: builds, tests ×5, bundle, harness, UI smoke, performance, privacy grep
./Scripts/dev_harness.sh        # throwaway listeners for manual checks (--check asserts them)
VERSION=1.2.0 ./Scripts/release.sh   # zip + DMG; signs and notarizes only when the secrets are present
```

- **Code layout**: `Sources/PortsCore` (no AppKit) holds scanning, detection, safety and stop logic.
  `Sources/PortsApp` is the menu bar app (AppKit + SwiftUI). `Sources/ports` is the CLI.
- **Further reading**: [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md),
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/FEATURES.md](docs/FEATURES.md).

MIT License.
