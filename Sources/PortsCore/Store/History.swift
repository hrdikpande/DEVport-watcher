// Phase 10: history — ports appearing and disappearing, and every stop action (who, what, method, result).
// JSON Lines in `~/Library/Application Support/<Brand>/history.jsonl`, pruned by age (default 7 days) and size.
import Foundation

public struct HistoryEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case appeared, disappeared, stop }
    public let at: Date
    public let kind: Kind
    public let port: Int?
    public let pid: Int32
    public let name: String
    public var by: String? = nil          // stop: app, cli, mcp
    public var method: String? = nil      // stop: signal ladder, brew services, launchctl bootout, docker stop, …
    public var result: String? = nil
    public init(at: Date, kind: Kind, port: Int?, pid: Int32, name: String, by: String? = nil, method: String? = nil, result: String? = nil) {
        self.at = at; self.kind = kind; self.port = port; self.pid = pid; self.name = name
        self.by = by; self.method = method; self.result = result
    }
    public var line: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let what = port.map { ":\($0) " } ?? ""
        switch kind {
        case .appeared: return "\(f.string(from: at))  + \(what)\(name) (PID \(pid))"
        case .disappeared: return "\(f.string(from: at))  − \(what)\(name) (PID \(pid))"
        case .stop: return "\(f.string(from: at))  ■ \(what)\(name) (PID \(pid)) by \(by ?? "app") · \(method ?? "stop") · \(result ?? "")"
        }
    }
}

/// Appeared / disappeared events between two scans (by listener instance: pid + start + port).
public func diffEvents(previous: [Listener], current: [Listener], now: Date = Date()) -> [HistoryEvent] {
    let before = Dictionary(previous.map { (listenerKey($0), $0) }, uniquingKeysWith: { a, _ in a })
    let after = Dictionary(current.map { (listenerKey($0), $0) }, uniquingKeysWith: { a, _ in a })
    let gone = before.filter { after[$0.key] == nil }.values.sorted { $0.port < $1.port }
        .map { HistoryEvent(at: now, kind: .disappeared, port: $0.port, pid: $0.pid, name: $0.label) }
    let new = after.filter { before[$0.key] == nil }.values.sorted { $0.port < $1.port }
        .map { HistoryEvent(at: now, kind: .appeared, port: $0.port, pid: $0.pid, name: $0.label) }
    return gone + new
}

public final class HistoryStore: @unchecked Sendable {
    public static var defaultURL: URL {
        supportDirectoryURL.appendingPathComponent("history.jsonl")
    }
    public let url: URL
    public let maxBytes: Int
    private let lock = NSLock()

    public init(url: URL = HistoryStore.defaultURL, maxBytes: Int = 2_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public func append(_ events: [HistoryEvent]) {
        guard !events.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let data = events.compactMap { try? Self.encoder.encode($0) }.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Events since a date (newest last), optionally only those matching `filter` (port, name, method).
    public func load(since: Date = .distantPast, filter: String = "") -> [HistoryEvent] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let f = filter.lowercased()
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(HistoryEvent.self, from: Data($0)) }
            .filter { $0.at >= since && (f.isEmpty || $0.line.lowercased().contains(f)) }
    }

    /// Drop events older than `retentionDays`, then the oldest until the file fits `maxBytes`.
    public func prune(retentionDays: Double, now: Date = Date()) {
        let keep = load(since: now.addingTimeInterval(-retentionDays * 86_400))
        lock.lock(); defer { lock.unlock() }
        var lines = keep.compactMap { try? Self.encoder.encode($0) }
        var size = lines.reduce(0) { $0 + $1.count + 1 }
        while size > maxBytes, !lines.isEmpty { size -= lines.removeFirst().count + 1 }
        let data = lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}
