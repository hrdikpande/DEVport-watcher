// Phase 10: energy behaviour and notification decisions.
// Cadence: fast while the panel is open, slow while closed, slower on battery / Low Power Mode,
// paused while asleep, locked, or paused by the user. Notifications: what changed that the user asked about.
import Foundation

public struct CadenceInput: Equatable, Sendable {
    public var panelOpen = false
    public var onBattery = false
    public var lowPower = false
    public var asleep = false
    public var screenLocked = false
    public var userPaused = false
    public init() {}
}

/// Seconds until the next scan; nil means don't scan (asleep, locked, paused, or paused on battery).
public func scanInterval(_ i: CadenceInput, settings: Settings) -> TimeInterval? {
    if i.asleep || i.screenLocked || i.userPaused { return nil }
    if i.panelOpen { return max(1, settings.refreshOpen) }
    if (i.onBattery || i.lowPower) && settings.pauseOnBattery { return nil }
    let base = max(2, settings.refreshClosed)
    return (i.onBattery || i.lowPower) ? base * 3 : base
}

/// Timer tolerance: at least half the interval, so macOS can coalesce wake-ups.
public func timerTolerance(_ interval: TimeInterval) -> TimeInterval { max(0.5 * interval, 0.1) }

// MARK: - Notifications

public enum NotificationKind: String, Sendable, CaseIterable {
    case watchedStarted, watchedStopped, watchedConflict, newOrphan, exposedDatabase, containerStopped
}

public struct PortNotification: Equatable, Sendable {
    public let kind: NotificationKind
    public let port: Int
    public let title: String
    public let body: String
    public let key: String              // listenerKey of the row the actions (Open, Copy address, Stop) act on
}

/// Who owned each watched port when Ports first saw it (to spot "taken by something else"). Thread-safe.
public final class WatchedOwners: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [Int: String] = [:]
    public init() {}
    func expected(_ port: Int, seen signature: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let o = owners[port] { return o }
        owners[port] = signature
        return signature
    }
    public func forget(_ port: Int) { lock.lock(); owners[port] = nil; lock.unlock() }
}

/// Notifications for what changed between two scans. Muted rows/ports never notify; each type has its toggle.
/// `stoppedByUs`: container names Ports itself stopped (not "unexpected").
public func notifications(previous: [Listener], current: [Listener], previousAnalysis: Analysis, analysis: Analysis,
                          settings: Settings, owners: WatchedOwners, stoppedByUs: Set<String> = []) -> [PortNotification] {
    func muted(_ l: Listener) -> Bool { l.override?.muted == true || settings.mutedPorts.contains(l.port) }
    let n = settings.notifications
    var out: [PortNotification] = []
    let beforePorts = Set(previous.map(\.port)), afterPorts = Set(current.map(\.port))
    if n.watchedPorts {
        for port in settings.watchedPorts.sorted() where !settings.mutedPorts.contains(port) {
            let now = current.filter { $0.port == port }
            if let l = now.first, !beforePorts.contains(port), !muted(l) {
                let expected = owners.expected(port, seen: serviceSignature(l))
                if expected != serviceSignature(l) {
                    out.append(PortNotification(kind: .watchedConflict, port: port, title: "Port \(port) was taken by something else",
                                                body: "\(l.label) (PID \(l.pid)) is now listening on :\(port).", key: listenerKey(l)))
                } else {
                    out.append(PortNotification(kind: .watchedStarted, port: port, title: "Port \(port) is up",
                                                body: "\(l.label) started listening.", key: listenerKey(l)))
                }
            } else if now.isEmpty, beforePorts.contains(port), let was = previous.first(where: { $0.port == port }), !muted(was) {
                out.append(PortNotification(kind: .watchedStopped, port: port, title: "Port \(port) stopped",
                                            body: "\(was.label) is no longer listening.", key: listenerKey(was)))
            }
        }
    }
    if n.newOrphan {
        for l in current where analysis.verdict(l)?.level == .confirmed && previousAnalysis.verdict(l)?.level != .confirmed && !muted(l) {
            out.append(PortNotification(kind: .newOrphan, port: l.port, title: "Orphaned dev server on :\(l.port)",
                                        body: "\(l.label): \(analysis.verdict(l)?.evidence.first ?? "nothing owns it any more").", key: listenerKey(l)))
        }
    }
    if n.exposedDatabase {
        let before = Set(previous.filter { $0.exposure.isNetworkReachable && knownDatabase($0) != nil }.map(listenerKey))
        for l in current where l.exposure.isNetworkReachable && knownDatabase(l) != nil && !before.contains(listenerKey(l)) && !muted(l) {
            out.append(PortNotification(kind: .exposedDatabase, port: l.port, title: "Database reachable from your network",
                                        body: "\(l.label) on :\(l.port) listens on \(l.addresses.joined(separator: ", ")).", key: listenerKey(l)))
        }
    }
    if n.containerStopped {
        for l in previous where l.container != nil && !afterPorts.contains(l.port) && !stoppedByUs.contains(l.container!) && !muted(l) {
            out.append(PortNotification(kind: .containerStopped, port: l.port, title: "Container \(l.container!) stopped",
                                        body: "It no longer publishes :\(l.port).", key: listenerKey(l)))
        }
    }
    return out
}
