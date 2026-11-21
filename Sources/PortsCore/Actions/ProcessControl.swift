// Phase 5: pause/resume, process trees, and second-stop escalation. Every signal goes through `verify`.
import Darwin
import Foundation

/// SIGSTOP an own process (identity re-checked first).
public func pause(pid: pid_t, start: UInt64) -> KillError? {
    if let err = verify(pid, start) { return err }
    return kill(pid, SIGSTOP) == 0 ? nil : .failed(String(cString: strerror(errno)))
}

/// SIGCONT an own process (identity re-checked first).
public func resume(pid: pid_t, start: UInt64) -> KillError? {
    if let err = verify(pid, start) { return err }
    return kill(pid, SIGCONT) == 0 ? nil : .failed(String(cString: strerror(errno)))
}

/// All descendants of `pid` (children, grandchildren, …) among `procs`, nearest first.
public func descendants(of pid: pid_t, in procs: [Proc.Brief]) -> [pid_t] {
    var children: [pid_t: [pid_t]] = [:]
    for p in procs where p.pid != p.ppid { children[p.ppid, default: []].append(p.pid) }
    var out: [pid_t] = [], queue = children[pid] ?? [], seen: Set<pid_t> = [pid]
    while !queue.isEmpty {
        let next = queue.removeFirst()
        guard seen.insert(next).inserted else { continue }
        out.append(next)
        queue += children[next] ?? []
    }
    return out
}

/// Stop targets for a process and its descendants: the root first (so a watcher can't respawn
/// anything), then the children. Children share the root's policy; vanished ones are skipped.
public func treeTargets(root: StopTarget, procs: [Proc.Brief] = Proc.all(uid: getuid())) -> [StopTarget] {
    [root] + descendants(of: root.pid, in: procs).compactMap { pid in
        guard let id = Proc.identity(pid), id.uid == getuid() else { return nil }
        return StopTarget(pid: pid, start: id.start, policy: root.policy, name: "child PID \(pid)")
    }
}

/// Remembers recent stops: a second Stop of the same process within `window` offers Force at once.
public final class RecentStops: @unchecked Sendable {
    public static let shared = RecentStops()
    private let lock = NSLock()
    private var at: [String: Date] = [:]
    public let window: TimeInterval
    public init(window: TimeInterval = 120) { self.window = window }

    public func record(_ key: String, now: Date = Date()) {
        lock.lock(); at[key] = now; at = at.filter { now.timeIntervalSince($0.value) < window }; lock.unlock()
    }
    public func isRecent(_ key: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return at[key].map { now.timeIntervalSince($0) < window } ?? false
    }
}
