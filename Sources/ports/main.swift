import ArgumentParser
import Darwin
import Foundation
import PortsCore

// `ports` — the CLI. Same PortsCore as the app: classification, verdicts and safety rules are identical.
// Every command takes --json. Exit codes: 0 ok · 1 not found / busy · 2 refused by safety rules ·
// 3 needs confirmation · 4 runtime error · 64 usage.

func finish(_ code: PortsCore.ExitCode) -> Never { fflush(stdout); Darwin.exit(code.rawValue) }
func fail(_ code: PortsCore.ExitCode, _ message: String, json: Bool) -> Never {
    if json { print(jsonString(["error": message, "exitCode": "\(code.rawValue)"])) } else { fputs(message + "\n", stderr) }
    finish(code)
}
func ms(_ since: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1e6 }

/// Scan with containers, plus (with `probe`) the same read-only loopback probes the open panel runs.
func freshScan(probe: Bool = false) -> [Listener] {
    var ls = scanWithContainers()
    if probe { ls = DatabaseProbeCache().apply(WebProbeCache().apply(ls, probe: true), probe: true) }
    ls = TunnelProbeCache().apply(ls, probe: probe, reverse: reverseForwards(sshArgvs()))
    return applyCustomMatchers(applyOverrides(ls, OverrideStore()), SettingsStore().settings.customMatchers)
}

func badges(_ l: Listener, _ a: Analysis) -> String {
    var b = ""
    if let v = a.verdict(l), v.level >= .likely { b += v.level == .confirmed ? "  ORPHAN" : "  ORPHAN?" }
    if a.isDuplicate(l) { b += "  TWICE" }
    if let (db, _) = knownDatabase(l) { b += "  DB:\(db.rawValue)" + (l.exposed ? "  NETWORK" : "") }
    if let w = l.webInfo {
        if !w.summary.isEmpty { b += "  " + w.summary }
        if w.isJSON { b += "  JSON" }
        if w.scheme == .https { b += "  HTTPS" }
    }
    if let url = l.tunnel?.publicURL { b += "  PUBLIC \(url)" }
    if let via = l.exposedVia { b += "  EXPOSED " + via }
    if l.proto == "udp" { b += "  UDP" }
    return b
}

func isInteractive() -> Bool { isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 }

func ask(_ question: String) -> Bool {
    print(question + " [y/N] ", terminator: "")
    fflush(stdout)
    return readLine()?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("y") == true
}

struct Common: ParsableArguments {
    @Flag(help: "Print JSON (schema: docs/schema/ports-list.schema.json).") var json = false
}

@main
struct Ports: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: Brand.cliName,
        abstract: "What is running locally, why, whether it is safe, and how to stop it.",
        discussion: "Exit codes: 0 ok, 1 not found / port busy, 2 refused by safety rules, 3 needs confirmation, 4 runtime error, 64 usage.\n`ports <port>` is short for `ports explain <port>`.",
        subcommands: [List.self, Explain.self, Stop.self, Free.self, Preflight.self, NextFree.self, Pause.self, Resume.self,
                      Cmd.self, Open.self, URLCommand.self, Watch.self, Doctor.self, Clean.self, History.self, MCP.self],
        defaultSubcommand: List.self)

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, Int(first) != nil { args.insert("explain", at: 0) }         // `ports 3000`
        if args.first == "--list" { args[0] = "list" }                                           // the old flag
        do {
            var command = try parseAsRoot(args)
            try command.run()
        } catch {
            let code = exitCode(for: error)
            if code == .success { print(fullMessage(for: error)); Darwin.exit(0) }                     // --help, --version
            fputs(fullMessage(for: error) + "\n", stderr)
            finish(.usage)
        }
    }
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List listening ports (default: the Developer view).")
    @OptionGroup var common: Common
    @Flag(help: "Include apps, services and system processes.") var all = false
    @Flag(help: "Developer categories only.") var dev = false
    @Option(help: "One category: frontend, backend, database, container, tunnel, ai, service, app, system.") var category: String?
    @Option(help: "Only this project (name or repo).") var project: String?
    @Option(help: "Only servers whose project or working directory is inside this folder.") var dir: String?
    @Option(help: "Only this port.") var port: Int?
    @Option(help: "Only ports in A-B.") var range: String?
    @Option(help: "Started within: 30m, 2h, 1d, today.") var since: String?
    @Flag(help: "Only containers.") var containers = false
    @Flag(help: "Only likely or confirmed orphans.") var orphans = false
    @Option(help: "port | uptime | mem | project") var sort = "port"
    @Flag(help: "TCP listeners (default).") var tcp = false
    @Flag(help: "Bound UDP sockets instead (read-only).") var udp = false
    @Flag(help: "Print scan timing.") var timing = false
    @Flag(help: "Show your own processes' environment, secret-looking values masked.") var env = false
    @Flag(help: "Run the read-only loopback probes the open panel runs (HTTP/TLS, DB handshakes, tunnel APIs).") var probe = false

    func run() throws {
        var q = ListQuery()
        q.all = all || udp; q.dev = dev; q.project = project; q.port = port; q.containers = containers; q.orphans = orphans
        q.dir = dir.map { ($0 as NSString).expandingTildeInPath }
        if let c = category { guard let k = Kind(id: c) else { throw ValidationError("Unknown category \(c).") }; q.category = k }
        if let r = range { guard let rr = parseRange(r) else { throw ValidationError("--range must be A-B, e.g. 3000-3999.") }; q.range = rr }
        if let s = since { guard let d = parseSince(s) else { throw ValidationError("--since must be like 30m, 2h, 1d or today.") }; q.since = d }
        guard ["port", "uptime", "mem", "project"].contains(sort) else { throw ValidationError("--sort must be port, uptime, mem or project.") }
        q.sort = sort

        let t0 = DispatchTime.now()
        let scanned = udp ? scanUDP() : freshScan(probe: probe)
        let full = ms(t0)
        let a = udp ? Analysis() : analyze(scanned, starred: OverrideStore().starred, includeLeftovers: true)
        let rows = applyQuery(scanned.filter { $0.override?.hidden != true }, q, analysis: a)
        if common.json { print(jsonString(envelope(rows, analysis: a))); finish(.ok) }
        for l in rows {
            print(listRow(l) + badges(l, a))
            if let why = KnownPorts.explanation(l) { print("        ↳ " + why) }
            if env, l.uid == getuid() {
                let e = maskedEnvironment(Proc.environment(l.pid))
                if e.isEmpty { print("        (environment not available: macOS withholds it for this process)") }
                for line in e { print("        " + line) }
            }
        }
        if !a.leftovers.isEmpty && !udp && q.port == nil {
            print("\nLeftovers (orphans without a port):")
            for left in a.leftovers { print("  PID \(left.process.pid)  \(left.tool)  ORPHAN") }
        }
        if timing {
            let t1 = DispatchTime.now()
            _ = scan(docker: [:])
            print(String(format: "\nscan: %.1f ms warm · first scan incl. containers: %.1f ms · %d processes · %d listeners",
                         ms(t1), full, Proc.allPIDs().count, scanned.count))
        }
        finish(rows.isEmpty && port != nil ? .notFound : .ok)
    }
}

// MARK: - explain

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Everything about one port: owners, who started them, verdict and evidence.")
    @OptionGroup var common: Common
    @Argument var port: Int

    func run() throws {
        guard (1...65535).contains(port) else { throw ValidationError("Port must be 1–65535.") }
        let ls = freshScan(probe: true)
        let a = analyze(ls, starred: OverrideStore().starred, includeLeftovers: false)
        let found = owners(ofPort: port, in: ls)
        if common.json {
            print(jsonString(found.map { portJSON($0, analysis: a) }))
            finish(found.isEmpty ? .notFound : .ok)
        }
        if found.isEmpty {
            print("Nothing is listening on port \(port).")
            if let k = KnownPorts.info(port: port) { print("Usually: \(k.owner) — \(k.explanation)") }
            finish(.notFound)
        }
        for l in found {
            let j = portJSON(l, analysis: a)
            print(":\(l.port)  \(l.label)  (\(l.kind.title)\(l.framework.map { ", " + $0 } ?? ""), \(l.confidence)% confident)")
            print("  PID \(l.pid), parent \(l.ppid) · \(l.exposed ? "reachable from your network" : "local only") (\(l.addresses.joined(separator: ", ")))")
            print("  \(tilde(l.command))")
            if !l.cwd.isEmpty { print("  cwd \(tilde(l.cwd))") }
            if let p = l.project { print("  project \(p.displayWithBranch)") }
            print("  \(formatUptime(j.uptimeSeconds)) · \(formatBytes(l.memory)) · \(l.connections) connection(s)")
            if let s = a.starter(l) { print("  started by \(s.name)\(s.pid.map { " (PID \($0))" } ?? "")") }
            if let v = a.verdict(l) {
                print("  safe to stop? \(v.safeToStop.title) · \(v.level.title)")
                for e in v.evidence { print("    • \(e)") }
            }
            if let why = KnownPorts.explanation(l) { print("  \(why)") }
            else if let k = KnownPorts.info(port: l.port) { print("  port \(l.port): \(k.owner) — \(k.explanation)") }
            if let c = l.containerInfo { print("  container \(c.label)") }
            if let (db, _) = knownDatabase(l), let url = connectionURL(db, l) { print("  \(db.title): \(url.absoluteString)") }
            if let t = l.tunnel { print("  \(t.summary)\(t.publicURL.map { " · " + $0 } ?? "")") }
            if let w = l.webInfo { print("  \(w.scheme.rawValue) \(w.summary)") }
        }
        finish(.ok)
    }
}

// MARK: - stop / free

/// The processes a `stop` target names, from a fresh scan. A PID that holds no port is still a target.
func resolveTargets(_ specs: [String], in ls: [Listener], json: Bool) -> [Listener] {
    var out: [Listener] = [], seen = Set<String>()
    for spec in specs {
        let isPID = spec.lowercased().hasPrefix("pid:")
        guard let n = Int(isPID ? String(spec.dropFirst(4)) : spec), n > 0 else { fail(.usage, "Not a port or PID: \(spec)", json: json) }
        var found: [Listener]
        if isPID || n > 65535 {
            found = ls.filter { $0.pid == pid_t(n) }
            if found.isEmpty, let b = Proc.bsdInfo(pid_t(n)) {
                let info = ProcessCache.shared.info(pid: pid_t(n), start: b.start)
                var l = Listener(port: 0, pid: pid_t(n), start: b.start, uid: b.uid, exposed: false, exe: info.exe,
                                 command: info.argv.joined(separator: " "), argv: info.argv, cwd: info.cwd)
                l.ppid = b.ppid
                l.chain = Proc.launcherChain(parent: b.ppid)
                let c = classifyDetailed(l)
                l.kind = c.kind; l.framework = c.framework?.name; l.tier = c.tier
                l.label = rowLabel(kind: c.kind, tool: c.name, cwd: info.cwd, project: info.project)
                found = [l]
            }
        } else {
            found = owners(ofPort: n, in: ls)
            if found.count > 1 {
                let list = found.map { "  PID \($0.pid)  \($0.label)  \($0.addresses.joined(separator: ", "))" }.joined(separator: "\n")
                fail(.needsConfirmation, "\(found.count) processes listen on port \(n); name one with pid:<PID>:\n" + list, json: json)
            }
        }
        if found.isEmpty { fail(.notFound, isPID ? "No process with PID \(n)." : "Nothing is listening on port \(n).", json: json) }
        for l in found where seen.insert(processKey(l)).inserted { out.append(l) }
    }
    return out
}

struct StopOptions: ParsableArguments {
    @Flag(help: "If it is still running after the ladder, force-kill it (SIGKILL). Databases still ask first.") var force = false
    @Flag(help: "Also stop its child processes (parent first).") var tree = false
    @Flag(help: "Accepted for clarity: a process is always stopped as a whole, so all its ports are freed.") var allPorts = false
    @Flag(help: "Show what would happen; change nothing.") var dryRun = false
    @Flag(help: "Don't ask for ordinary confirmations. Never bypasses protected ports or database warnings.") var yes = false
}

/// The CLI stop flow: supervisor-aware plan → safety decision → confirmation → core execute → history → port report.
/// Returns true when every port of the targets is free afterwards.
func stopTargets(_ targets: [Listener], _ o: StopOptions, json: Bool) -> Bool {
    let settings = SettingsStore().settings
    let registry = StopRegistry()
    var results: [[String: String]] = []
    var worst = PortsCore.ExitCode.ok
    for l in targets {
        let a = analyze([l], includeLeftovers: false)
        let s = a.starter(l) ?? starter(of: l.chain, isLaunchdJob: false)
        var methods = stopMethods(l, starter: s, ctx: supervisorContext(for: l, starter: s))
        if o.tree, case .signal(let t)? = methods.first { methods = [.tree(treeTargets(root: t))] }
        let decision = cliStopDecision(l, methods: methods, settings: settings, yes: o.yes)
        var method: StopMethod
        switch decision {
        case .refuse(let why):
            results.append(["port": "\(l.port)", "pid": "\(l.pid)", "result": "refused", "reason": why])
            if !json { fputs("Refused :\(l.port) \(l.label) (PID \(l.pid)): \(why)\n", stderr) }
            worst = .refused; continue
        case .proceed(let m): method = m
        case .confirm(let text, let m):
            method = m
            if o.dryRun { break }
            guard isInteractive() else {
                results.append(["port": "\(l.port)", "pid": "\(l.pid)", "result": "needs confirmation", "plan": text])
                if !json { fputs("Needs confirmation for :\(l.port) \(l.label) (PID \(l.pid)). Run it in a terminal\(StopPolicy(l) == .dataStore ? "" : " or pass --yes"):\n\(text)\n", stderr) }
                if worst == .ok { worst = .needsConfirmation }
                continue
            }
            print("\(text)\n")
            guard ask("Stop \(l.label) (PID \(l.pid))?") else { if worst == .ok { worst = .needsConfirmation }; continue }
        }
        let plan = confirmation(method, for: l)
        if o.dryRun {
            results.append(["port": "\(l.port)", "pid": "\(l.pid)", "result": "dry run", "plan": plan.text])
            if !json { print("Would stop :\(l.port) \(l.label) (PID \(l.pid))\n\(plan.text)\n") }
            continue
        }
        let err = execute(method, registry: registry)
        var outcome = err?.description ?? "stopped"
        if err == nil, o.force, Proc.identity(l.pid)?.start == l.start {
            if StopPolicy(l) == .dataStore && !(isInteractive() && ask("\(l.label) is still running. Force-kill it (may lose data)?")) {
                outcome = "still running (force not confirmed)"
            } else {
                outcome = forceKill(pid: l.pid, start: l.start)?.description ?? "force-killed"
            }
        }
        HistoryStore().append([HistoryEvent(at: Date(), kind: .stop, port: l.port > 0 ? l.port : nil, pid: l.pid, name: l.label,
                                            by: "cli", method: plan.how, result: outcome)])
        results.append(["port": "\(l.port)", "pid": "\(l.pid)", "result": outcome])
        if err != nil { worst = .runtimeError }
        if !json { print("\(l.label) (PID \(l.pid)): \(outcome)") }
    }
    let fresh = scanWithContainers()
    let ports = Set(targets.map(\.port).filter { $0 > 0 }).sorted()
    let still = ports.filter { !owners(ofPort: $0, in: fresh).isEmpty }
    if json { print(jsonString(StopReport(results: results, stillListening: still))) }
    else if !o.dryRun { for p in ports { print(portReport(p, owners: owners(ofPort: p, in: fresh))) } }
    if worst != .ok { finish(worst) }
    return still.isEmpty
}

struct StopReport: Encodable { let results: [[String: String]]; let stillListening: [Int] }

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop what listens on ports (or PIDs: pid:<n>) through the safe ladder or its supervisor.")
    @OptionGroup var common: Common
    @OptionGroup var options: StopOptions
    @Argument(help: "Ports, or pid:<PID>.") var targets: [String]

    func run() throws {
        let ls = freshScan()
        let free = stopTargets(resolveTargets(targets, in: ls, json: common.json), options, json: common.json)
        finish(free || options.dryRun ? .ok : .notFound)
    }
}

struct Free: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Free ports, then run a command in this terminal: ports free 3000 -- npm run dev")
    @OptionGroup var common: Common
    @OptionGroup var options: StopOptions
    @Argument(parsing: .captureForPassthrough, help: "<port…> -- <command…>") var rest: [String] = []

    func run() throws {
        // Split the raw arguments at `--` (the parser may or may not keep the terminator in `rest`).
        let raw = CommandLine.arguments
        guard let dash = raw.firstIndex(of: "--") else { throw ValidationError("Use: ports free <port…> -- <command…>") }
        let command = Array(raw[(dash + 1)...])
        let ports = rest.prefix { $0 != "--" }.filter { Int($0) != nil }
        guard !ports.isEmpty, !command.isEmpty else { throw ValidationError("Use: ports free <port…> -- <command…>") }
        let ls = freshScan()
        let busy = ports.filter { Int($0).map { !owners(ofPort: $0, in: ls).isEmpty } ?? true }
        if !busy.isEmpty { _ = stopTargets(resolveTargets(busy, in: ls, json: common.json), options, json: common.json) }
        let fresh = scanWithContainers()
        for p in ports.compactMap(Int.init) {
            let c = checkPort(p, listeners: fresh)
            if !c.free { fail(.notFound, c.message, json: common.json) }
        }
        // Replace this process with the user's own command, in the foreground of their terminal (exec, not a child).
        var cargs = command.map { strdup($0) } + [nil]
        execvp(command[0], &cargs)
        fail(.runtimeError, "Couldn't run \(command[0]): \(String(cString: strerror(errno)))", json: common.json)
    }
}

// MARK: - preflight / next-free / pause / resume / cmd / open / url

struct Preflight: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Are these ports free? Bind probe included. Exit 0 if all are free.")
    @OptionGroup var common: Common
    @Argument var ports: [Int]
    func run() throws {
        guard ports.allSatisfy({ (1...65535).contains($0) }) else { throw ValidationError("Ports must be 1–65535.") }
        let ls = scanWithContainers()
        let checks = ports.map { checkPort($0, listeners: ls) }
        if common.json { print(jsonString(checks.map { ["port": "\($0.port)", "free": $0.free ? "true" : "false", "message": $0.message] })) }
        else { for c in checks { print(c.message) } }
        finish(checks.allSatisfy(\.free) ? .ok : .notFound)
    }
}

struct NextFree: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "next-free", abstract: "The first free port at or above --from.")
    @OptionGroup var common: Common
    @Option var from = 3000
    func run() throws {
        guard (1...65535).contains(from) else { throw ValidationError("--from must be 1–65535.") }
        guard let p = nextFreePort(from: from, listeners: scanWithContainers()) else { fail(.notFound, "No free port near \(from).", json: common.json) }
        print(common.json ? jsonString(["port": p]) : String(p))
        finish(.ok)
    }
}

func singleTarget(_ spec: String, json: Bool) -> Listener {
    let t = resolveTargets([spec], in: freshScan(), json: json)
    if t.count != 1 { fail(.needsConfirmation, "\(spec) names several processes.", json: json) }
    return t[0]
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Suspend (SIGSTOP) your own process on a port or PID.")
    @OptionGroup var common: Common
    @Argument var target: String
    func run() throws {
        let l = singleTarget(target, json: common.json)
        if let e = pause(pid: l.pid, start: l.start) { fail(.refused, e.description, json: common.json) }
        print(common.json ? jsonString(["pid": "\(l.pid)", "result": "paused"]) : "Paused \(l.label) (PID \(l.pid))")
        finish(.ok)
    }
}

struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume (SIGCONT) a paused process.")
    @OptionGroup var common: Common
    @Argument var target: String
    func run() throws {
        let l = singleTarget(target, json: common.json)
        if let e = resume(pid: l.pid, start: l.start) { fail(.refused, e.description, json: common.json) }
        print(common.json ? jsonString(["pid": "\(l.pid)", "result": "resumed"]) : "Resumed \(l.label) (PID \(l.pid))")
        finish(.ok)
    }
}

struct Cmd: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the command that started the server on a port.")
    @OptionGroup var common: Common
    @Argument var port: Int
    @Flag(help: "Also copy it to the clipboard.") var copy = false
    func run() throws {
        let l = singleTarget(String(port), json: common.json)
        guard l.uid == getuid() else { fail(.refused, "It belongs to another user.", json: common.json) }
        let c = l.startCommand
        if copy { _ = PortsCore.run("/usr/bin/pbcopy", [], input: Data(c.utf8)) }
        print(common.json ? jsonString(["port": "\(port)", "command": c]) : c)
        finish(.ok)
    }
}

func webURL(_ port: Int, json: Bool) -> URL {
    var l = singleTarget(String(port), json: json)
    l.web = probeWeb(l)
    guard let scheme = l.web, let url = browserURL(l, scheme) else { fail(.notFound, "Port \(port) doesn't answer HTTP.", json: json) }
    return url
}

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open a port in the browser (with the right scheme).")
    @OptionGroup var common: Common
    @Argument var port: Int
    func run() throws {
        let url = webURL(port, json: common.json)
        _ = PortsCore.run("/usr/bin/open", [url.absoluteString])
        print(common.json ? jsonString(["url": url.absoluteString]) : url.absoluteString)
        finish(.ok)
    }
}

struct URLCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "url", abstract: "Print a port's URL.")
    @OptionGroup var common: Common
    @Argument var port: Int
    func run() throws {
        let url = webURL(port, json: common.json)
        print(common.json ? jsonString(["url": url.absoluteString]) : url.absoluteString)
        finish(.ok)
    }
}

// MARK: - watch / doctor / clean / history / mcp

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stream port changes (NDJSON with --json). Ctrl-C to stop.")
    @OptionGroup var common: Common
    @Option(help: "Seconds between scans (e.g. 2 or 2s).") var interval = "2"
    @Flag(help: "Also show a macOS notification for each change.") var notify = false
    @Option(help: "Stop after this many scans (0 = forever).") var count = 0
    func run() throws {
        guard let secs = Double(interval.trimmingCharacters(in: CharacterSet(charactersIn: "s"))), secs >= 0.5 else {
            throw ValidationError("--interval must be at least 0.5 s.")
        }
        var previous = scan(docker: [:])
        var n = 0
        while count == 0 || n < count {
            Thread.sleep(forTimeInterval: secs)
            n += 1
            let current = scan(docker: [:])
            for e in diffEvents(previous: previous, current: current) {
                print(common.json ? jsonString(e, pretty: false) : e.line)
                if notify {
                    let text = e.line.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\\", with: "/")
                    _ = PortsCore.run("/usr/bin/osascript", ["-e", "display notification \"\(text)\" with title \"\(Brand.displayName)\""])
                }
            }
            fflush(stdout)
            previous = current
        }
        finish(.ok)
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Health issues. --fix --yes applies only safe fixes (stopping confirmed orphans).")
    @OptionGroup var common: Common
    @Flag var fix = false
    @Flag var yes = false
    func run() throws {
        let ls = freshScan()
        var input = DoctorInput()
        input.localhostIPv6First = localhostPrefersIPv6()
        let a = analyze(ls, starred: OverrideStore().starred, includeLeftovers: true, doctor: input)
        if common.json { print(jsonString(a.issues.map { ["id": $0.id, "severity": $0.severity.title, "title": $0.title, "explanation": $0.explanation] })) }
        else if a.issues.isEmpty { print("No issues.") }
        else { for i in a.issues { print("[\(i.severity.title)] \(i.title)\n    \(i.explanation)") } }
        if fix {
            guard yes else { fail(.needsConfirmation, "--fix needs --yes.", json: common.json) }
            let orphans = ls.filter { a.verdict($0)?.level == .confirmed && StopPolicy($0).autoForce } + a.leftovers.map(\.process)
            let outs = orphans.isEmpty ? [] : stopAll(orphans.map(StopTarget.init), registry: StopRegistry())
            for (l, o) in zip(orphans, outs) {
                HistoryStore().append([HistoryEvent(at: Date(), kind: .stop, port: l.port > 0 ? l.port : nil, pid: l.pid, name: l.label,
                                                    by: "cli", method: "doctor --fix (signal ladder)", result: o.summary)])
                if !common.json { print("fixed: " + o.summary) }
            }
        }
        finish(a.issues.isEmpty ? .ok : .notFound)
    }
}

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop orphaned processes (confirmed; --include-likely adds likely ones).")
    @OptionGroup var common: Common
    @Flag var dryRun = false
    @Flag var includeLikely = false
    @Flag(help: "Don't ask.") var yes = false
    func run() throws {
        let ls = freshScan()
        let a = analyze(ls, starred: OverrideStore().starred, includeLeftovers: true)
        let minimum: OrphanLevel = includeLikely ? .likely : .confirmed
        let targets = ls.filter { $0.uid == getuid() && (a.verdict($0)?.level ?? .notOrphan) >= minimum } + a.leftovers.map(\.process)
        let lines = targets.map { "\($0.port > 0 ? ":\($0.port) " : "")\($0.label) — PID \($0.pid) · \(StopPolicy($0).autoForce ? "SIGTERM, SIGKILL after 2 s" : "SIGTERM only")" }
        if targets.isEmpty { print(common.json ? "[]" : "No orphans."); finish(.ok) }
        if dryRun || (!yes && !isInteractive()) {
            if common.json { print(jsonString(lines)) } else { print("Would stop:\n" + lines.map { "  " + $0 }.joined(separator: "\n")) }
            finish(dryRun ? .ok : .needsConfirmation)
        }
        if !yes {
            print("Will stop:\n" + lines.map { "  " + $0 }.joined(separator: "\n"))
            guard ask("Clean up \(targets.count) process(es)?") else { finish(.needsConfirmation) }
        }
        let outs = stopAll(targets.map(StopTarget.init), registry: StopRegistry())
        for (l, o) in zip(targets, outs) {
            HistoryStore().append([HistoryEvent(at: Date(), kind: .stop, port: l.port > 0 ? l.port : nil, pid: l.pid, name: l.label,
                                                by: "cli", method: "clean (signal ladder)", result: o.summary)])
        }
        print(common.json ? jsonString(outs.map(\.summary)) : outs.map(\.summary).joined(separator: "\n"))
        finish(outs.allSatisfy { $0.error == nil && !$0.refused } ? .ok : .runtimeError)
    }
}

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Port appear/disappear events and stop actions.")
    @OptionGroup var common: Common
    @Option(help: "30m, 2h, 1d, today") var since: String?
    func run() throws {
        var from = Date.distantPast
        if let s = since { guard let d = parseSince(s) else { throw ValidationError("--since must be like 30m, 2h, 1d or today.") }; from = d }
        let events = HistoryStore().load(since: from)
        if common.json { print(jsonString(events)) } else { for e in events { print(e.line) } }
        finish(.ok)
    }
}

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Model Context Protocol server over stdio (enable it in Settings › Command Line & Agents).")
    func run() throws {
        guard SettingsStore().settings.mcpEnabled else {
            fputs("The MCP server is off. Turn it on in \(Brand.displayName) › Settings › Command Line & Agents.\n", stderr)
            finish(.refused)
        }
        var env = MCPEnvironment()
        let core = env.stop
        env.stop = { l in
            let r = core(l)
            _ = PortsCore.run("/usr/bin/osascript", ["-e", "display notification \"An agent stopped :\(l.port) (PID \(l.pid))\" with title \"\(Brand.displayName)\""])
            return r
        }
        MCPServer(env: env).run()
        finish(.ok)
    }
}
