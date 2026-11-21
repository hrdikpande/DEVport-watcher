# Architecture

Ports is three Swift package targets sharing one core, so classification, verdicts and safety rules are identical
everywhere.

```text
PortsCore   (no AppKit/SwiftUI; everything testable)
├── Model/      Listener, Exposure, Kind (categories)
├── Scan/       SocketScanner (libproc, TCP + UDP), ProcessReader/ProcessModel (argv, cwd, tree, metrics, TTY,
│               connections, static cache by pid+start), BindProbe (bind-only port check, next free port)
├── Detect/     Frameworks (data table), Classifier, KnownPorts, SystemPorts, ProjectResolver + GitInfo,
│               AgentDetector (who started it), OrphanAnalyzer (verdicts, leftovers, duplicates, bulk stop),
│               DatabaseDetector (process/image/read-only handshakes), TunnelDetector (ssh/kubectl/ngrok/cloudflared…)
├── Docker/     DockerRuntimeLocator (every runtime's socket), DockerEngineClient (HTTP/1.1 over unix socket),
│               ContainerMapper (proxy → container, cadence, actions)
├── Actions/    Terminator (verify → SIGTERM/SIGCONT → wait → SIGKILL only for dev servers; StopRegistry),
│               ProcessControl (pause/resume, trees, second-stop), Supervisor (brew/launchd/pm2/nodemon/Docker/app
│               plans + four-part confirmations)
├── Web/        HTTPProbe (scheme), WebProbe (status/time/title, bounded, cached; loopback only)
├── Store/      Settings, Overrides, History (JSONL) — all under ~/Library/Application Support/Ports
│               (or $PORTS_SUPPORT_DIR)
├── Panel/      PanelLogic (filters, search, sort, sections, NEW, status summary, custom matchers)
├── CLI/        Output (JSON model + schema, queries, exit codes, CLI/MCP stop rules), MCPServer (JSON-RPC stdio)
├── Doctor      Health issues and safe fixes
├── SnapshotService   Scan cadence (open/closed/battery/sleep) and notification decisions
├── Privacy     The list of every probe (Settings › Privacy and README)
└── Exec        The only place that launches child processes (fixed paths, argv, minimal env, timeout)

PortsApp    AppKit status item + SwiftUI popover panel + Settings window
├── AppDelegate (status item, popover, timer, sleep/wake/lock, scan pipeline), Actions (every flow),
│   PanelModel/PanelView (rows, badges, details, inline prompts, keyboard, VoiceOver), SettingsView,
│   SystemServices (notifications, Carbon hot key, power source, login item, CLI install, opt-in update check),
│   Prompter (inline confirmations with alert fallback)

ports       swift-argument-parser CLI (list, explain, stop, free, preflight, next-free, pause, resume, cmd, open, url,
            watch, doctor, clean, history, mcp); embedded at Ports.app/Contents/Helpers/ports
```

## Data flow

1. **Socket scan.** On each tick, `scan` walks every process's sockets. Static per-process data is cached by
   PID and start time.
2. **Panel open.** The same scan also samples CPU, runs the web and database probes (loopback only, budgeted,
   cached), reads the tunnel agents' local APIs, and runs the orphan analysis, which reads `launchctl list`.
3. **Containers.** Engines are queried only when a runtime's port proxy listens: on every open, at most once a
   minute while closed, and at once when the proxies change.
4. **Diffs.** Each scan's diff feeds History and the notification decisions. The UI updates only when something
   changed.

## Safety invariants

- **One core path.** Every stop — app, CLI, MCP, bulk clean-up, supervisor — goes through PortsCore: StopRegistry
  (one flow per process), `verify` (PID + start time + uid, never PID 1 or self), then the StopPolicy ladder.
- **Auto-escalation.** Only Frontend/Backend dev servers are SIGKILLed automatically.
- **Overrides are display only.** Overrides and custom matchers change what is shown, never how something is
  stopped or probed (`baseKind`).
- **Probes.** They run only while the panel is open (or with an explicit `--probe`), only on loopback, and are
  read-only. Databases, tunnels and LAN-only binds are never web-probed.
- **Internet.** The only request to the internet is the opt-in daily update check.
