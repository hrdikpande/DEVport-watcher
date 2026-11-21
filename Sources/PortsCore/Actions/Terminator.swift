import Darwin
import Foundation

// MARK: - Safe kill

public enum KillError: Error, Equatable, Sendable, CustomStringConvertible {
    case gone, notYours, protected, failed(String)
    public var description: String {
        switch self {
        case .gone: "That process has already exited (its PID may now belong to something else), so nothing was killed."
        case .notYours: "It belongs to the system or another user. Ports only stops your own processes."
        case .protected: "Ports won't stop this process."
        case .failed(let s): s
        }
    }
}

/// How carefully a process is stopped.
public enum StopPolicy: Equatable, Sendable {
    case devServer      // Frontend/Backend: 2 s grace, then SIGKILL
    case app            // System & Apps, container engine, unknown: 5 s grace, never an automatic SIGKILL
    case dataStore      // databases & brokers: 15 s grace, never an automatic SIGKILL

    public init(_ l: Listener) {
        switch l.baseKind {
        case .frontend, .backend: self = .devServer
        case .database: self = .dataStore
        case .docker, .tunnel, .ai, .service, .app, .system: self = .app   // containers stop via `docker stop`
        }
    }

    public var grace: TimeInterval { switch self { case .devServer: 2; case .app: 5; case .dataStore: 15 } }
    /// Only dev servers you started are force-killed automatically; everything else needs explicit Force Quit.
    public var autoForce: Bool { self == .devServer }
    /// Most careful first, for a PID that owns several listeners.
    var caution: Int { switch self { case .devServer: 0; case .app: 1; case .dataStore: 2 } }
    public var warning: String? {
        self == .dataStore
            ? "Databases and brokers can lose or corrupt data that isn't flushed to disk. Ports asks it to shut down "
              + "cleanly and waits up to 15 s; it never force-kills automatically."
            : nil
    }

    /// The policy for a PID: the most careful of its listeners; an unknown process is treated as an app.
    public static func strictest(_ ls: [Listener]) -> StopPolicy {
        ls.map(StopPolicy.init).max { $0.caution < $1.caution } ?? .app
    }
}

func verify(_ pid: pid_t, _ start: UInt64) -> KillError? {
    guard pid > 1, pid != getpid() else { return .protected }
    guard let id = Proc.identity(pid), id.start == start else { return .gone }
    guard id.uid == getuid() else { return .notYours }
    return nil
}

/// SIGTERM (+ SIGCONT if suspended), wait `grace`, then SIGKILL only if `escalate` —
/// re-verifying identity before each signal.
public func safeTerminate(pid: pid_t, start: UInt64, grace: TimeInterval = 2, escalate: Bool = true) -> KillError? {
    if let err = verify(pid, start) { return err }
    if kill(pid, SIGTERM) != 0 { return .failed(String(cString: strerror(errno))) }
    if Proc.isStopped(pid) { kill(pid, SIGCONT) }                // a suspended process can't act on SIGTERM
    let deadline = Date().addingTimeInterval(grace)
    while Date() < deadline {
        usleep(100_000)
        if Proc.identity(pid)?.start != start { return nil }       // exited
    }
    if escalate, Proc.identity(pid)?.start == start { kill(pid, SIGKILL) }
    return nil
}

public func safeTerminate(pid: pid_t, start: UInt64, policy: StopPolicy) -> KillError? {
    safeTerminate(pid: pid, start: start, grace: policy.grace, escalate: policy.autoForce)
}

/// The separate, explicit Force step: SIGKILL now.
public func forceKill(pid: pid_t, start: UInt64) -> KillError? {
    if let err = verify(pid, start) { return err }
    return kill(pid, SIGKILL) == 0 ? nil : .failed(String(cString: strerror(errno)))
}

/// At most one stop flow per process (or container): a second request while one runs is refused,
/// so it can't start a second ladder or a second alert.
public final class StopRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = Set<String>()
    public init() {}

    public static func key(pid: pid_t, start: UInt64) -> String { "\(pid)-\(start)" }

    /// True if the caller now owns the flow for `key`; false if one is already running.
    public func claim(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return busy.insert(key).inserted }
    public func release(_ key: String) { lock.lock(); busy.remove(key); lock.unlock() }
    public func isBusy(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return busy.contains(key) }

    /// Run `body` only if no flow for `key` is running; nil when refused.
    public func once<T>(_ key: String, _ body: () -> T) -> T? {
        guard claim(key) else { return nil }
        defer { release(key) }
        return body()
    }
}

/// What a fresh rescan says about a port after a stop.
public func portReport(_ port: Int, owners: [Listener]) -> String {
    let still = owners.filter { $0.port == port }
    guard !still.isEmpty else { return "Port \(port) is free" }
    return "Still listening: " + still.map { "\($0.label.isEmpty ? basename($0.exe) : $0.label) (PID \($0.pid))" }
        .joined(separator: ", ")
}

/// Every process listening on `port`, from a fresh scan, one entry per PID.
public func owners(ofPort port: Int, in listeners: [Listener]) -> [Listener] {
    var seen = Set<pid_t>()
    return listeners.filter { $0.port == port && seen.insert($0.pid).inserted }.sorted { $0.pid < $1.pid }
}
