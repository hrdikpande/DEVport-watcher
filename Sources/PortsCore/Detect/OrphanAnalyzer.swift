// Phase 4: orphan verdicts with plain-English evidence, duplicates, idle tracking, leftovers, bulk stop.
import Darwin
import Foundation

public enum OrphanLevel: Int, Sendable, Comparable, CaseIterable {
    case notOrphan, possible, likely, confirmed
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var title: String { ["Not an orphan", "Possible orphan", "Likely orphan", "Orphan"][rawValue] }
}

/// green: nothing owns it · yellow: duplicate or weak evidence · red: a live launcher still owns it.
public enum SafeToStop: String, Sendable {
    case green, yellow, red
    public var title: String { ["green": "Safe to stop", "yellow": "Probably safe to stop", "red": "Something still owns it"][rawValue]! }
}

public struct OrphanVerdict: Equatable, Sendable {
    public let level: OrphanLevel
    public let evidence: [String]
    public let safeToStop: SafeToStop
}

/// What the analyzer needs beyond the listener itself; filled once per scan.
public struct OrphanContext: Sendable {
    public var launchdJobs: [pid_t: String] = [:]   // pid -> label (`launchctl list`, your user's jobs)
    public var liveTTYs: Set<Int32> = []            // terminals that a live shell/terminal/multiplexer still holds
    public var duplicates: Set<String> = []         // process keys with another instance of the same project+framework
    public var idleSince: [String: Date] = [:]      // listener key -> first scan with 0 connections
    public var exitedStarters: [String: Starter] = [:]
    public var starred: Set<String> = []            // service signatures
    public var idleThreshold: TimeInterval = 30 * 60
    public var now = Date()
    public var home = PortsCore.home
    public init() {}
}

public func processKey(_ l: Listener) -> String { "\(l.pid)-\(l.start)" }
public func listenerKey(_ l: Listener) -> String { "\(l.pid)-\(l.start)-\(l.port)" }

let shellNames: Set = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "login", "tmux", "screen"]

/// Terminals still in use: held by a live shell or multiplexer.
public func liveTTYs(_ procs: [Proc.Brief]) -> Set<Int32> {
    Set(procs.compactMap { p in p.tty.flatMap { shellNames.contains(p.name.lowercased()) ? $0 : nil } })
}

/// "brew services (postgresql@16)" for Homebrew labels, else the label.
public func describeJob(_ label: String) -> String {
    label.hasPrefix("homebrew.mxcl.") ? "brew services (\(label.dropFirst("homebrew.mxcl.".count)))" : "launchd job \(label)"
}

/// Orphan verdict. Exclusions come first and are never flagged: starred, launchd jobs and brew services,
/// pm2, containers, apps in /Applications, and anything a live terminal, editor or agent still runs.
/// `devTool`: the caller already knows it is a dev tool (a leftover watcher matched by pattern).
public func analyzeOrphan(_ l: Listener, starter: Starter, ctx: OrphanContext, devTool: Bool = false) -> OrphanVerdict {
    func keep(_ why: String) -> OrphanVerdict { OrphanVerdict(level: .notOrphan, evidence: [why], safeToStop: .red) }
    if ctx.starred.contains(serviceSignature(l)) { return keep("You starred it, so Ports never flags it.") }
    if let label = ctx.launchdJobs[l.pid] { return keep("Run by \(describeJob(label)); launchd may restart it.") }
    if starter.name == "pm2" { return keep("Managed by pm2, which restarts it.") }
    if l.baseKind == .docker || l.container != nil { return keep("Managed by the container runtime.") }
    if l.baseKind == .system { return keep("A macOS system process.") }
    // A script runtime is judged by its script, not by where the runtime is installed.
    let judged = scriptArgument(exe: l.exe, argv: l.argv).map { $0.hasPrefix("/") ? $0 : l.cwd + "/" + $0 } ?? l.exe
    if judged.hasPrefix("/Applications/") || judged.hasPrefix(ctx.home + "/Applications/") || l.baseKind == .app {
        return keep("Part of \(appName(l.exe)), an installed app.")
    }
    if let p = starter.pid, starter.kind != .unknown {
        return keep("\(starter.name) (PID \(p)) is still running it.")
    }
    // The top of its tree: the process launchd adopted or started (itself when its parent is launchd).
    let topAncestor = l.chain.last { $0.pid != 1 }
    let top = topAncestor?.pid ?? l.pid
    if top != l.pid, let label = ctx.launchdJobs[top] { return keep("Its tree was started by \(describeJob(label)).") }
    if let a = topAncestor, let uid = a.uid, uid != l.uid {
        return keep("Started under \(a.command) (PID \(a.pid)), a process of another user such as a system service.")
    }

    let key = processKey(l)
    let adopted = topAncestor == nil ? l.ppid == 1 : l.chain.last?.pid == 1
    let devServer = devTool || l.baseKind == .frontend || l.baseKind == .backend
    var evidence: [String] = []
    var strong = false
    if adopted {
        evidence.append(topAncestor == nil
            ? "Its parent exited: launchd (PID 1) adopted it, and it isn't a launchd job."
            : "The shell or tool that launched it was orphaned too: launchd (PID 1) adopted PID \(top), which isn't a launchd job.")
    }
    if let tty = l.tty, !ctx.liveTTYs.contains(tty) {
        evidence.append("The terminal session it ran in is gone."); strong = true
    } else if let tty = l.tty, ctx.liveTTYs.contains(tty), !adopted {
        return keep("A terminal session is still open behind it.")
    }
    if l.tty == nil && devServer {
        evidence.append(l.port > 0 ? "It has no terminal: a dev server running detached." : "It has no terminal: a dev tool running detached.")
        strong = true
    }
    if let s = ctx.exitedStarters[key] {
        evidence.append("\(s.name)\(s.pid.map { " (PID \($0))" } ?? ""), which started it, is no longer running."); strong = true
    }
    var weak = 0
    if ctx.duplicates.contains(key) { evidence.append("Another instance of the same project and server is running."); weak += 1 }
    if let since = ctx.idleSince[listenerKey(l)], ctx.now.timeIntervalSince(since) >= ctx.idleThreshold {
        evidence.append("No connections for \(Int(ctx.now.timeIntervalSince(since) / 60)) min."); weak += 1
    }
    if l.stopped { evidence.append("Suspended (Ctrl-Z): it holds the port but serves nothing."); weak += 1 }

    if adopted && strong { return OrphanVerdict(level: .confirmed, evidence: evidence, safeToStop: .green) }
    if adopted { return OrphanVerdict(level: .likely, evidence: evidence, safeToStop: .green) }
    if weak > 0 { return OrphanVerdict(level: .possible, evidence: evidence, safeToStop: .yellow) }
    let parent = l.chain.first.map { "\($0.command) (PID \($0.pid))" } ?? "its parent"
    return keep("Its launcher \(parent) is still running.")
}

// MARK: - launchd jobs

/// `launchctl list`: "PID\tStatus\tLabel" rows; PID is "-" for jobs that aren't running.
public func parseLaunchctlList(_ out: String) -> [pid_t: String] {
    var jobs: [pid_t: String] = [:]
    for line in out.split(separator: "\n") {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count >= 3, let pid = pid_t(cols[0]), pid > 0 else { continue }
        jobs[pid] = String(cols[2])
    }
    return jobs
}

/// Your user's launchd jobs, refreshed at most every 30 s (only asked for when a candidate needs it).
public final class LaunchdJobs: @unchecked Sendable {
    public static let shared = LaunchdJobs()
    private let lock = NSLock()
    private var cached: [pid_t: String] = [:]
    private var at = Date.distantPast
    public init() {}
    /// A fixed job list (tests, or a caller that already has one): never runs launchctl.
    public init(fixed: [pid_t: String]) { cached = fixed; at = .distantFuture }
    public func current(maxAge: TimeInterval = 30) -> [pid_t: String] {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(at) < maxAge { return cached }
        let r = run("/bin/launchctl", ["list"], timeout: 2)
        if r.ok { cached = parseLaunchctlList(r.out); at = Date() }
        return cached
    }
}

// MARK: - Duplicates

/// Same project root + same framework running more than once (distinct processes), oldest first.
public func duplicateGroups(_ ls: [Listener]) -> [[Listener]] {
    var groups: [String: [Listener]] = [:]
    for l in ls where l.baseKind == .frontend || l.baseKind == .backend {
        guard let root = l.project?.root else { continue }
        groups["\(root)|\(l.framework ?? basename(l.exe))", default: []].append(l)
    }
    return groups.values.compactMap { g in
        var seen = Set<pid_t>()
        let distinct = g.filter { seen.insert($0.pid).inserted }.sorted { $0.start < $1.start }
        return distinct.count > 1 ? distinct : nil
    }.sorted { $0[0].port < $1[0].port }
}

// MARK: - Idle and starters over time

/// Remembers when each listener was first seen with no connections. Thread-safe.
public final class IdleTracker: @unchecked Sendable {
    public static let shared = IdleTracker()
    private let lock = NSLock()
    private var since: [String: Date] = [:]
    public init() {}
    public func update(_ ls: [Listener], now: Date = Date()) -> [String: Date] {
        lock.lock(); defer { lock.unlock() }
        var next: [String: Date] = [:]
        for l in ls where l.connections == 0 { next[listenerKey(l)] = since[listenerKey(l)] ?? now }
        since = next
        return next
    }
}

/// Remembers who started each process, so a later scan can say "Claude Code, which started it, has exited".
public final class StarterMemory: @unchecked Sendable {
    public static let shared = StarterMemory()
    private let lock = NSLock()
    private var seen: [String: (starter: Starter, start: UInt64)] = [:]
    public init() {}

    /// Record live starters; return the remembered ones whose process has since exited.
    public func update(_ items: [(key: String, starter: Starter)],
                       startOf: (pid_t) -> UInt64? = { Proc.bsdInfo($0)?.start }) -> [String: Starter] {
        lock.lock(); defer { lock.unlock() }
        var exited: [String: Starter] = [:], next: [String: (Starter, UInt64)] = [:]
        for (key, s) in items {
            if let p = s.pid, s.kind != .unknown, p != 1, let start = startOf(p) {
                next[key] = (s, start)
            } else if let old = seen[key] {
                if let p = old.starter.pid, startOf(p) != old.start { exited[key] = old.starter } else { next[key] = old }
            }
        }
        seen = next.mapValues { ($0.0, $0.1) }
        return exited
    }
}

// MARK: - Leftovers (orphans without ports)

struct LeftoverPattern: Sendable {
    let names: [String]
    let args: [String]        // any one of these must be present; empty = none needed
}

/// Watchers and helpers that commonly outlive the terminal or agent that started them.
let leftoverPatterns: [LeftoverPattern] = [
    .init(names: ["tsc"], args: ["-w", "--watch"]),
    .init(names: ["esbuild"], args: ["--watch"]),
    .init(names: ["vite"], args: ["--watch", "-w"]),
    .init(names: ["webpack"], args: ["--watch", "-w"]),
    .init(names: ["rollup"], args: ["--watch", "-w"]),
    .init(names: ["electron-vite"], args: []),
    .init(names: ["nodemon"], args: []),
    .init(names: ["ts-node-dev", "tsnd"], args: []),
    .init(names: ["tsx"], args: ["watch"]),
    .init(names: ["jest"], args: ["--watch", "--watchAll"]),
    .init(names: ["vitest"], args: []),
    .init(names: ["tailwindcss"], args: ["--watch", "-w"]),
]

func isLeftoverTool(exe: String, argv: [String]) -> String? {
    let names = identityNames(exe: exe, argv: argv)
    if names.contains(where: { $0.contains("mcp") }) || argv.contains(where: { $0.hasPrefix("@modelcontextprotocol/") }) {
        return names.last { $0.contains("mcp") } ?? names.last
    }
    for p in leftoverPatterns {
        guard let n = names.dropFirst().first(where: { t in p.names.contains { nameMatches(t, $0) } })
                ?? names.first(where: { t in p.names.contains { nameMatches(t, $0) } }) else { continue }
        if p.args.isEmpty || p.args.contains(where: argv.contains) { return n }
    }
    return nil
}

public struct Leftover: Equatable, Sendable {
    public let process: Listener        // port 0: a process, not a listener
    public let tool: String
    public let verdict: OrphanVerdict
}

/// Your processes without a listening port that match a watcher/MCP pattern and are confirmed orphans
/// (strict rules only). Reads argv through `cache`; meant for panel-open scans.
public func findLeftovers(excluding listenerPIDs: Set<pid_t>, ctx: OrphanContext, cache: ProcessCache = .shared,
                          procs: [Proc.Brief] = Proc.all(uid: getuid())) -> [Leftover] {
    var out: [Leftover] = []
    let byPID = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    for p in procs where !listenerPIDs.contains(p.pid) && p.pid != getpid() {
        // Cheap filter first: only processes whose ancestry reaches launchd without a terminal shell.
        var cur = p, hops = 0
        while cur.ppid > 1, let parent = byPID[cur.ppid], hops < 16 { cur = parent; hops += 1 }
        guard cur.ppid == 1 || cur.pid == 1, let bsd = Proc.bsdInfo(p.pid) else { continue }
        let info = cache.info(pid: p.pid, start: bsd.start)
        guard let tool = isLeftoverTool(exe: info.exe, argv: info.argv) else { continue }
        var l = Listener(port: 0, pid: p.pid, start: bsd.start, uid: bsd.uid, exposed: false, exe: info.exe,
                         command: info.argv.joined(separator: " "), argv: info.argv, cwd: info.cwd)
        l.ppid = bsd.ppid
        l.tty = p.tty
        l.chain = Proc.launcherChain(parent: bsd.ppid, cache: cache)
        l.project = info.project
        let c = classifyDetailed(l)
        l.kind = c.kind
        l.framework = c.framework?.name
        l.tier = c.tier
        l.label = tool
        let jobs = ctx.launchdJobs
        let s = starter(of: l.chain, isLaunchdJob: jobs[l.pid] != nil)
        let v = analyzeOrphan(l, starter: s, ctx: ctx, devTool: true)
        if v.level == .confirmed { out.append(Leftover(process: l, tool: tool, verdict: v)) }
    }
    return out.sorted { $0.process.start < $1.process.start }
}

// MARK: - Bulk stop (one core path for app, CLI and MCP)

public struct StopTarget: Sendable, Equatable {
    public let pid: pid_t
    public let start: UInt64
    public let policy: StopPolicy
    public let name: String
    public init(pid: pid_t, start: UInt64, policy: StopPolicy, name: String) {
        self.pid = pid; self.start = start; self.policy = policy; self.name = name
    }
    public init(_ l: Listener) { self.init(pid: l.pid, start: l.start, policy: StopPolicy(l), name: l.label) }
}

public struct StopOutcome: Sendable, Equatable {
    public let target: StopTarget
    public let error: KillError?
    public let refused: Bool          // another stop flow for this process is already running
    public let stillRunning: Bool     // didn't exit within its grace (never force-killed unless its policy allows)
    public var summary: String {
        if refused { return "\(target.name) (PID \(target.pid)): already being stopped" }
        if let error { return "\(target.name) (PID \(target.pid)): \(error.description)" }
        return "\(target.name) (PID \(target.pid)): " + (stillRunning ? "still running — use Force Quit" : "stopped")
    }
}

/// Stop each target through the same ladder as a single stop: one flow per process (`registry`),
/// identity re-checked before every signal, SIGKILL only where the policy allows (dev servers).
public func stopAll(_ targets: [StopTarget], registry: StopRegistry) -> [StopOutcome] {
    targets.map { t in
        let key = StopRegistry.key(pid: t.pid, start: t.start)
        guard let err = registry.once(key, { safeTerminate(pid: t.pid, start: t.start, policy: t.policy) }) else {
            return StopOutcome(target: t, error: nil, refused: true, stillRunning: Proc.identity(t.pid)?.start == t.start)
        }
        return StopOutcome(target: t, error: err, refused: false,
                           stillRunning: err == nil && Proc.identity(t.pid)?.start == t.start)
    }
}
