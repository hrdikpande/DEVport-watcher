// Phase 11: the CLI's JSON output (schema: docs/schema/ports-list.schema.json), list filters, exit codes and
// the stop decision rules the CLI and MCP share with the app (same core: StopRegistry, verify, StopPolicy).
import Darwin
import Foundation

/// Stable exit codes (documented in README and `ports --help`).
public enum ExitCode: Int32, Sendable {
    case ok = 0
    case notFound = 1          // nothing found, or a port is busy when it should be free
    case refused = 2           // refused by the safety rules
    case needsConfirmation = 3 // needs an interactive confirmation (or --yes)
    case runtimeError = 4
    case usage = 64
}

public let jsonSchemaVersion = 1

public struct PortJSON: Codable, Equatable, Sendable {
    public struct ProjectJSON: Codable, Equatable, Sendable { public let name: String; public let repo: String?; public let root: String; public let branch: String? }
    public struct ContainerJSON: Codable, Equatable, Sendable { public let name: String; public let image: String?; public let project: String?; public let service: String?; public let health: String? }
    public struct DatabaseJSON: Codable, Equatable, Sendable { public let type: String; public let source: String }
    public struct TunnelJSON: Codable, Equatable, Sendable { public let kind: String; public let summary: String; public let publicURL: String? }
    public struct WebJSON: Codable, Equatable, Sendable { public let scheme: String; public let status: Int?; public let ms: Int?; public let title: String?; public let json: Bool }
    public struct OrphanJSON: Codable, Equatable, Sendable { public let level: String; public let safeToStop: String; public let evidence: [String] }
    public struct StarterJSON: Codable, Equatable, Sendable { public let kind: String; public let name: String; public let pid: Int32? }
    public struct KnownJSON: Codable, Equatable, Sendable { public let owner: String; public let explanation: String; public let howToFree: String? }

    public let port: Int
    public let proto: String
    public let pid: Int32
    public let process: String
    public let exe: String
    public let command: String
    public let cwd: String
    public let kind: String
    public let category: String
    public let label: String
    public let framework: String?
    public let confidence: Int
    public let tier: String
    public let addresses: [String]
    public let exposure: String              // loopback | all | specific
    public let reachableFromNetwork: Bool
    public let stopped: Bool
    public let startedAt: String
    public let uptimeSeconds: Int
    public let memoryBytes: UInt64
    public let cpuPercent: Double?
    public let connections: Int
    public let workers: [Int32]
    public let parentPID: Int32
    public let project: ProjectJSON?
    public let container: ContainerJSON?
    public let database: DatabaseJSON?
    public let tunnel: TunnelJSON?
    public let web: WebJSON?
    public let orphan: OrphanJSON?
    public let startedBy: StarterJSON?
    public let duplicate: Bool
    public let knownPort: KnownJSON?
    public let startCommand: String?
}

func iso(_ start: UInt64) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(start) / 1_000_000))
}

public func portJSON(_ l: Listener, analysis: Analysis, now: Date = Date(), uid: uid_t = getuid()) -> PortJSON {
    let exposure: String = { switch l.exposure { case .loopback: "loopback"; case .allInterfaces: "all"; case .specific: "specific" } }()
    let v = analysis.verdict(l)
    let s = analysis.starter(l)
    let k = KnownPorts.info(port: l.port)
    return PortJSON(
        port: l.port, proto: l.proto, pid: l.pid, process: appName(l.exe), exe: l.exe, command: l.command, cwd: l.cwd,
        kind: l.kind.id, category: l.kind.title, label: l.label, framework: l.framework, confidence: l.confidence,
        tier: l.tier.rawValue, addresses: l.addresses, exposure: exposure, reachableFromNetwork: l.exposed, stopped: l.stopped,
        startedAt: iso(l.start), uptimeSeconds: uptimeSeconds(start: l.start, now: now), memoryBytes: l.memory,
        cpuPercent: l.cpuPercent, connections: l.connections, workers: l.workers, parentPID: l.ppid,
        project: l.project.map { .init(name: $0.name, repo: $0.repo, root: $0.root, branch: $0.branch) },
        container: l.container.map { n in .init(name: n, image: l.containerInfo?.image, project: l.containerInfo?.project,
                                                service: l.containerInfo?.service, health: l.containerInfo?.health) },
        database: knownDatabase(l).map { .init(type: $0.0.rawValue, source: $0.1.rawValue) },
        tunnel: l.tunnel.map { .init(kind: $0.kind, summary: $0.summary, publicURL: $0.publicURL ?? l.publicURL) },
        web: l.webInfo.map { .init(scheme: $0.scheme.rawValue, status: $0.status, ms: $0.ms, title: $0.title, json: $0.isJSON) }
            ?? l.web.map { .init(scheme: $0.rawValue, status: nil, ms: nil, title: nil, json: false) },
        orphan: v.map { .init(level: ["notOrphan", "possible", "likely", "confirmed"][$0.level.rawValue], safeToStop: $0.safeToStop.rawValue, evidence: $0.evidence) },
        startedBy: s.map { .init(kind: $0.kind.rawValue, name: $0.name, pid: $0.pid) },
        duplicate: analysis.isDuplicate(l),
        knownPort: k.map { .init(owner: $0.owner, explanation: $0.explanation, howToFree: $0.howToFree) },
        startCommand: l.uid == uid && !l.argv.isEmpty ? l.startCommand : nil)
}

public struct ListEnvelope: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let ports: [PortJSON]
}

public func jsonString<T: Encodable>(_ value: T, pretty: Bool = true) -> String {
    let e = JSONEncoder()
    e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    return (try? e.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}

public func envelope(_ ls: [Listener], analysis: Analysis, now: Date = Date()) -> ListEnvelope {
    ListEnvelope(schemaVersion: jsonSchemaVersion, generatedAt: ISO8601DateFormatter().string(from: now),
                 ports: ls.map { portJSON($0, analysis: analysis, now: now) })
}

// MARK: - List filters

public struct ListQuery: Sendable, Equatable {
    public var all = false              // include apps, services, system
    public var dev = false              // developer kinds only (the default view)
    public var category: Kind? = nil
    public var project: String? = nil
    public var dir: String? = nil
    public var port: Int? = nil
    public var range: ClosedRange<Int>? = nil
    public var since: Date? = nil       // started after
    public var containers = false
    public var orphans = false
    public var sort = "port"            // port | uptime | mem | project
    public init() {}
}

/// "30m", "2h", "1d", "today" -> a date in the past; nil when invalid.
public func parseSince(_ s: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
    if s == "today" { return calendar.startOfDay(for: now) }
    guard let unit = s.last, let n = Double(s.dropLast()), n >= 0 else { return nil }
    let mult: Double? = ["s": 1, "m": 60, "h": 3600, "d": 86_400][unit]
    return mult.map { now.addingTimeInterval(-n * $0) }
}

/// "3000-3999" -> 3000...3999.
public func parseRange(_ s: String) -> ClosedRange<Int>? {
    let p = s.split(separator: "-").compactMap { Int($0) }
    guard p.count == 2, p[0] >= 1, p[1] <= 65535, p[0] <= p[1] else { return nil }
    return p[0]...p[1]
}

public func applyQuery(_ ls: [Listener], _ q: ListQuery, analysis: Analysis) -> [Listener] {
    let dir = q.dir.map { ($0 as NSString).standardizingPath }
    let narrowed = q.category != nil || q.containers || q.orphans || q.port != nil
    let rows = ls.filter { l in
        if !q.all && !narrowed && l.proto == "tcp" && !showsInDeveloperView(l) { return false }
        if q.dev && !l.kind.isDeveloper { return false }
        if let c = q.category, l.kind != c { return false }
        if let p = q.project?.lowercased(), !(l.project?.name.lowercased() == p || l.project?.repo?.lowercased() == p) { return false }
        if let d = dir, !(l.cwd == d || l.cwd.hasPrefix(d + "/") || (l.project?.root).map({ $0 == d || $0.hasPrefix(d + "/") }) == true) { return false }
        if let p = q.port, l.port != p { return false }
        if let r = q.range, !r.contains(l.port) { return false }
        if let s = q.since, Double(l.start) / 1_000_000 < s.timeIntervalSince1970 { return false }
        if q.containers && l.container == nil && l.baseKind != .docker { return false }
        if q.orphans && (analysis.verdict(l)?.level ?? .notOrphan) < .likely { return false }
        return true
    }
    switch q.sort {
    case "uptime": return rows.sorted { ($0.start, $0.port) < ($1.start, $1.port) }
    case "mem": return rows.sorted { $0.memory != $1.memory ? $0.memory > $1.memory : $0.port < $1.port }
    case "project": return rows.sorted { ($0.project?.display ?? "~", $0.port) < ($1.project?.display ?? "~", $1.port) }
    default: return rows.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }
}

// MARK: - Stop decisions (CLI)

public enum StopDecision: Equatable, Sendable {
    case proceed(StopMethod)
    case refuse(String)                 // exit 2
    case confirm(String, StopMethod)    // ask (interactive) or exit 3
}

/// What `ports stop` may do with one listener. `--yes` skips the ordinary confirmation, never the protected-port or
/// database rules: a protected port is refused here (stop it from the menu bar), a database always asks interactively.
public func cliStopDecision(_ l: Listener, methods: [StopMethod], settings: Settings, yes: Bool, uid: uid_t = getuid()) -> StopDecision {
    guard let first = methods.first else { return .refuse("Nothing to do.") }
    if case .explain(let why) = first { return .refuse(why) }
    if l.uid != uid || l.tier == .blocked { return .refuse("It belongs to the system or another user. Ports only stops your own processes.") }
    if settings.isProtected(l.port) {
        return .refuse("Port \(l.port) is protected. Stop it from the menu bar, where you confirm by typing the port number.")
    }
    // An app is quit by the menu bar app (like ⌘Q); from the CLI it gets the gentle ladder (SIGTERM, never an automatic SIGKILL).
    var method = first
    if case .app = first { method = .signal(StopTarget(l)) }
    let text = confirmation(method, for: l).text + (StopPolicy(l).warning.map { "\n\n" + $0 } ?? "")
    if StopPolicy(l) == .dataStore || knownDatabase(l) != nil { return .confirm(text, method) }
    return yes ? .proceed(method) : .confirm(text, method)
}

// MARK: - MCP stop gate

/// nil when an agent may stop this listener through MCP; otherwise why not. Off unless both settings are on, and
/// even then only your own `safe`-tier dev servers: never databases, containers, apps, system processes or protected ports.
public func mcpStopRefusal(_ l: Listener, settings: Settings, uid: uid_t = getuid()) -> String? {
    if !settings.mcpEnabled { return "The MCP server is turned off in Settings › Command Line & Agents." }
    if !settings.mcpAllowStop { return "Stopping is off: turn on “Allow agents to stop processes” in Settings › Command Line & Agents." }
    if l.uid != uid { return "It belongs to the system or another user." }
    if l.container != nil || l.baseKind == .docker { return "Agents can't stop containers." }
    if knownDatabase(l) != nil || l.baseKind == .database { return "Agents can't stop databases." }
    if l.baseKind == .app || l.baseKind == .system || l.baseKind == .service { return "Agents can't stop apps, services or system processes." }
    if settings.isProtected(l.port) { return "Port \(l.port) is protected." }
    if l.tier != .safe { return "Only dev servers you started can be stopped by an agent." }
    return nil
}
