// Phase 4: Doctor — health issues with plain explanations and, where safe, a one-click fix.
import Darwin
import Foundation

public enum Severity: Int, Sendable, Comparable {
    case info, warning, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var title: String { ["Info", "Warning", "Critical"][rawValue] }
}

public enum Fix: Equatable, Sendable {
    case cleanUpLeftovers                       // opens the bulk clean-up confirmation
    case stopOlder(pid: pid_t, start: UInt64)   // duplicates: the older instance
    case openURL(URL)
}

public struct Issue: Equatable, Sendable {
    public let id: String
    public let severity: Severity
    public let title: String
    public let explanation: String
    public let fix: Fix?
    public var fixTitle: String? {
        switch fix {
        case .cleanUpLeftovers: "Clean Up…"
        case .stopOlder: "Stop the Older One…"
        case .openURL: "Open Settings"
        case nil: nil
        }
    }
}

/// Everything derived from one scan for the UI and CLI: verdicts, starters, duplicates, leftovers, issues.
public struct Analysis: Sendable {
    public var starters: [String: Starter] = [:]          // processKey -> starter
    public var verdicts: [String: OrphanVerdict] = [:]    // processKey -> verdict
    public var duplicates: [[Listener]] = []
    public var leftovers: [Leftover] = []
    public var issues: [Issue] = []
    public init() {}

    public func verdict(_ l: Listener) -> OrphanVerdict? { verdicts[processKey(l)] }
    public func starter(_ l: Listener) -> Starter? { starters[processKey(l)] }
    public func isDuplicate(_ l: Listener) -> Bool { duplicates.contains { g in g.contains { $0.pid == l.pid } } }
    /// The older instance of a duplicate group this listener belongs to (nil if it is the oldest).
    public func olderInstance(of l: Listener) -> Listener? {
        guard let g = duplicates.first(where: { g in g.contains { $0.pid == l.pid } }), g[0].pid != l.pid else { return nil }
        return g[0]
    }
}

let databaseImages = ["postgres", "mysql", "mariadb", "mongo", "redis", "valkey", "memcached", "clickhouse", "cockroach",
                      "influxdb", "elasticsearch", "opensearch", "neo4j", "couchdb", "rabbitmq", "kafka", "nats", "surrealdb",
                      "cassandra", "mssql", "sqlserver"]
/// "postgres:16", "bitnami/redis:7", "mcr.microsoft.com/mssql/server" -> a database image.
public func isDatabaseImage(_ image: String) -> Bool {
    let repo = image.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
    return repo.split(separator: "/").contains { part in databaseImages.contains { part.hasPrefix($0) } }
}

/// Whether `localhost` resolves to ::1 before 127.0.0.1 here (from /etc/hosts; no network).
public func localhostPrefersIPv6() -> Bool {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo("localhost", nil, &hints, &res) == 0, let first = res else { return false }
    defer { freeaddrinfo(res) }
    return first.pointee.ai_family == AF_INET6
}

public struct DoctorInput: Sendable {
    public var dockerReachable: Bool? = nil     // nil: no runtime detected
    public var localhostIPv6First = false
    public var idleThreshold: TimeInterval = 30 * 60
    public var idleSince: [String: Date] = [:]
    public var now = Date()
    public init() {}
}

/// Health issues, most severe first.
public func diagnose(_ ls: [Listener], _ a: Analysis, _ input: DoctorInput) -> [Issue] {
    var issues: [Issue] = []
    let orphans = ls.filter { a.verdict($0)?.level == .confirmed }
    let count = orphans.count + a.leftovers.count
    if count > 0 {
        let what = (orphans.map { ":\($0.port) \($0.label)" } + a.leftovers.map { $0.tool }).prefix(4).joined(separator: ", ")
        issues.append(Issue(id: "orphans", severity: .warning,
                            title: "\(count) orphaned process\(count == 1 ? "" : "es")",
                            explanation: "Nothing owns \(count == 1 ? "it" : "them") any more: \(what). Clean up stops only what you confirm.",
                            fix: .cleanUpLeftovers))
    }
    for g in a.duplicates {
        let ports = g.map { ":\($0.port)" }.joined(separator: ", ")
        let name = g[0].framework ?? g[0].label
        issues.append(Issue(id: "dup-\(g[0].pid)", severity: .warning,
                            title: "\(g[0].project?.display ?? name) is running \(g.count == 2 ? "twice" : "\(g.count) times")",
                            explanation: "\(name) from the same project listens on \(ports). The oldest is PID \(g[0].pid).",
                            fix: .stopOlder(pid: g[0].pid, start: g[0].start)))
    }
    for l in ls where l.baseKind == .database && l.exposure.isNetworkReachable {
        issues.append(Issue(id: "dbexposed-\(l.pid)-\(l.port)", severity: .critical,
                            title: "\(l.framework ?? l.label) on :\(l.port) is reachable from your network",
                            explanation: "It listens on \(l.addresses.joined(separator: ", ")). Bind it to 127.0.0.1 unless other machines need it.",
                            fix: nil))
    }
    for l in ls {
        guard let c = l.containerInfo, c.publishedOnAllInterfaces(l.port) else { continue }
        let priv = c.ports.first { $0.publicPort == l.port }?.privatePort ?? l.port
        issues.append(Issue(id: "publish-\(c.name)-\(l.port)", severity: l.baseKind == .database || isDatabaseImage(c.image) ? .critical : .warning,
                            title: "Container \(c.name) publishes :\(l.port) on all interfaces",
                            explanation: "Anyone on your network can reach it. Publish it as 127.0.0.1:\(l.port):\(priv) (compose: \"127.0.0.1:\(l.port):\(priv)\") unless other machines need it.",
                            fix: nil))
    }
    for l in ls where l.stopped {
        issues.append(Issue(id: "stopped-\(l.pid)-\(l.port)", severity: .info,
                            title: "PID \(l.pid) is suspended on :\(l.port)",
                            explanation: "\(l.label) was paused (Ctrl-Z or SIGSTOP). It holds the port but answers nothing.",
                            fix: nil))
    }
    for l in ls where (l.baseKind == .frontend || l.baseKind == .backend) {
        guard let since = input.idleSince[listenerKey(l)], input.now.timeIntervalSince(since) >= input.idleThreshold else { continue }
        issues.append(Issue(id: "idle-\(l.pid)-\(l.port)", severity: .info,
                            title: "\(l.label) on :\(l.port) has been idle \(Int(input.now.timeIntervalSince(since) / 60)) min",
                            explanation: "No connections since Ports first saw it idle.", fix: nil))
    }
    if input.dockerReachable == false {
        issues.append(Issue(id: "docker", severity: .warning, title: "Container runtime isn't answering",
                            explanation: "A runtime's port proxy is running, but its engine didn't answer, so container names are missing.",
                            fix: nil))
    }
    // localhost vs 127.0.0.1/::1: one issue per direction, listing the ports (not one per server).
    let loopbackDev = ls.filter { ($0.baseKind == .frontend || $0.baseKind == .backend) && $0.exposure == .loopback }
    func ports(_ xs: [Listener]) -> String { Set(xs.map(\.port)).sorted().prefix(8).map { ":\($0)" }.joined(separator: ", ") }
    let v4only = loopbackDev.filter { l in l.addresses.allSatisfy { !$0.contains(":") } }
    let v6only = loopbackDev.filter { l in l.addresses.allSatisfy { $0.contains(":") } }
    if input.localhostIPv6First && !v4only.isEmpty {
        issues.append(Issue(id: "localhost-v4", severity: .info,
                            title: "\(v4only.count) server\(v4only.count == 1 ? "" : "s") listen\(v4only.count == 1 ? "s" : "") on 127.0.0.1 only",
                            explanation: "localhost resolves to ::1 first on this Mac, so some clients (Node 17+, curl) fail before trying 127.0.0.1: \(ports(v4only)). Use 127.0.0.1 in URLs or bind ::1 too.",
                            fix: nil))
    }
    if !input.localhostIPv6First && !v6only.isEmpty {
        issues.append(Issue(id: "localhost-v6", severity: .info,
                            title: "\(v6only.count) server\(v6only.count == 1 ? "" : "s") listen\(v6only.count == 1 ? "s" : "") on ::1 only",
                            explanation: "localhost resolves to 127.0.0.1 first on this Mac, so IPv4 clients can't reach \(ports(v6only)). Use [::1] in URLs or bind 127.0.0.1 too.",
                            fix: nil))
    }
    return issues.sorted { $0.severity > $1.severity }
}

/// One pass over a scan: starters, duplicates, idle, orphan verdicts, (optionally) leftovers, issues.
/// The stateful trackers carry information between scans (idle time, starters that later exited).
public func analyze(_ ls: [Listener], starred: Set<String> = [], includeLeftovers: Bool = false,
                    doctor input: DoctorInput = DoctorInput(), jobs: LaunchdJobs = .shared, jobsMaxAge: TimeInterval = 30,
                    idle: IdleTracker = .shared, memory: StarterMemory = .shared,
                    procs: [Proc.Brief]? = nil) -> Analysis {
    var a = Analysis()
    let all = procs ?? Proc.all(uid: getuid())
    var ctx = OrphanContext()
    ctx.starred = starred
    ctx.liveTTYs = liveTTYs(all)
    ctx.now = input.now
    ctx.idleThreshold = input.idleThreshold
    // launchctl only when something could be a launchd job: a process (or its tree) adopted by launchd.
    if ls.contains(where: { $0.ppid == 1 || $0.chain.last?.pid == 1 }) || includeLeftovers {
        ctx.launchdJobs = jobs.current(maxAge: jobsMaxAge)
    }
    ctx.idleSince = idle.update(ls, now: input.now)
    a.duplicates = duplicateGroups(ls)
    ctx.duplicates = Set(a.duplicates.flatMap { $0.map(processKey) })
    for l in ls { a.starters[processKey(l)] = starter(of: l.chain, isLaunchdJob: ctx.launchdJobs[l.pid] != nil) }
    ctx.exitedStarters = memory.update(a.starters.map { ($0.key, $0.value) })
    for l in ls where a.verdicts[processKey(l)] == nil {
        a.verdicts[processKey(l)] = analyzeOrphan(l, starter: a.starters[processKey(l)]!, ctx: ctx)
    }
    if includeLeftovers { a.leftovers = findLeftovers(excluding: Set(ls.map(\.pid)), ctx: ctx, procs: all) }
    var d = input
    d.idleSince = ctx.idleSince
    a.issues = diagnose(ls, a, d)
    return a
}

/// A prompt for a coding agent: which ports and projects are in use and how to ask Ports about them.
public func aiSetupPrompt(_ ls: [Listener], cli: String = Brand.cliName) -> String {
    let dev = ls.filter { $0.baseKind.isDeveloper }
    var lines = ["Local services on this Mac, as seen by \(Brand.displayName):"]
    if dev.isEmpty { lines.append("- (none running)") }
    for l in dev.sorted(by: { $0.port < $1.port }) {
        var row = "- :\(l.port) \(l.framework ?? l.label)"
        if let p = l.project { row += " — project \(p.displayWithBranch)" }
        row += " (PID \(l.pid), \(l.exposure.isNetworkReachable ? "reachable from the network" : "local only"))"
        lines.append(row)
    }
    lines += ["",
              "Before starting a server, check the port is free: `\(cli) preflight <port>` (exit 0 = free), or find one with `\(cli) next-free --from 3000`.",
              "List what's running with `\(cli) list --json`; explain a port with `\(cli) explain <port>`.",
              "Don't stop processes you didn't start. If a port is taken, ask the user or pick another port.",
              "An MCP server is available: `\(cli) mcp` (tools: list_ports, explain_port, is_port_free, find_free_port, list_orphans, project_servers)."]
    return lines.joined(separator: "\n")
}
