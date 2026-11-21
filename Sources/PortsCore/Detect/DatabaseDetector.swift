// Phase 7: databases. Detected by process, by container image, or (panel open / explicit `--probe`
// only) by a read-only protocol handshake on an unknown loopback port. Never sends credentials.
import Darwin
import Foundation

public enum DatabaseType: String, Sendable, Codable, CaseIterable {
    case postgres, mysql, redis, mongodb, memcached, amqp, clickhouse, elasticsearch, kafka, other
    public var title: String {
        ["postgres": "PostgreSQL", "mysql": "MySQL", "redis": "Redis", "mongodb": "MongoDB", "memcached": "Memcached",
         "amqp": "RabbitMQ (AMQP)", "clickhouse": "ClickHouse", "elasticsearch": "Elasticsearch", "kafka": "Kafka",
         "other": "Database"][rawValue]!
    }
    /// URL scheme database clients register for; nil when there isn't one.
    public var scheme: String? {
        ["postgres": "postgres", "mysql": "mysql", "redis": "redis", "mongodb": "mongodb", "amqp": "amqp"][rawValue]
    }
}

public enum DatabaseSource: String, Sendable { case process, image, handshake }

/// From a framework display name (the process table).
public func databaseType(framework: String?) -> DatabaseType? {
    switch framework {
    case "PostgreSQL", "CockroachDB": .postgres
    case "MySQL", "MariaDB": .mysql
    case "Redis", "Valkey": .redis
    case "MongoDB": .mongodb
    case "Memcached": .memcached
    case "RabbitMQ": .amqp
    case "ClickHouse": .clickhouse
    case "Elasticsearch", "OpenSearch": .elasticsearch
    case "Kafka": .kafka
    case nil: nil
    default: framework.flatMap { name in frameworks.first { $0.name == name && $0.kind == .database } }.map { _ in .other }
    }
}

/// From a container image ("postgres:16", "bitnami/redis", "mysql/mysql-server").
public func databaseType(image: String) -> DatabaseType? {
    guard isDatabaseImage(image) else { return nil }
    let repo = image.lowercased().split(separator: ":").first.map(String.init) ?? ""
    let table: [(String, DatabaseType)] = [("postgres", .postgres), ("postgis", .postgres), ("timescale", .postgres),
                                           ("mysql", .mysql), ("mariadb", .mysql), ("redis", .redis), ("valkey", .redis),
                                           ("mongo", .mongodb), ("memcached", .memcached), ("rabbitmq", .amqp),
                                           ("clickhouse", .clickhouse), ("elasticsearch", .elasticsearch),
                                           ("opensearch", .elasticsearch), ("kafka", .kafka)]
    for part in repo.split(separator: "/").reversed() {
        if let hit = table.first(where: { part.hasPrefix($0.0) }) { return hit.1 }
    }
    return .other
}

/// The database a listener is, from what's known without touching the network.
public func knownDatabase(_ l: Listener) -> (DatabaseType, DatabaseSource)? {
    if l.baseKind == .database, let t = databaseType(framework: l.framework) { return (t, .process) }
    if let img = l.containerInfo?.image, let t = databaseType(image: img) { return (t, .image) }
    if let t = l.probedDatabase { return (t, .handshake) }
    return nil
}

// MARK: - Handshakes (read-only; each its own connection)

/// PostgreSQL SSLRequest: length 8, code 80877103. The server answers one byte: 'S' or 'N'.
let pgSSLRequest: [UInt8] = [0, 0, 0, 8, 0x04, 0xd2, 0x16, 0x2f]
let redisPing = Array("PING\r\n".utf8)
let memcachedVersion = Array("version\r\n".utf8)
let amqpHeader: [UInt8] = Array("AMQP".utf8) + [0, 0, 9, 1]

/// MongoDB OP_MSG `{hello: 1, $db: "admin"}` (no auth, no data).
let mongoHello: [UInt8] = {
    func le32(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    var doc: [UInt8] = [0x10] + Array("hello".utf8) + [0] + le32(1)
    doc += [0x02] + Array("$db".utf8) + [0] + le32(6) + Array("admin".utf8) + [0]
    let bson = le32(Int32(doc.count + 5)) + doc + [0]
    let body = le32(0) + [0] + bson                         // flagBits, section kind 0, document
    return le32(Int32(16 + body.count)) + le32(1) + le32(0) + le32(2013) + body
}()

public func isPostgresReply(_ b: [UInt8]) -> Bool { b.count == 1 && (b[0] == UInt8(ascii: "S") || b[0] == UInt8(ascii: "N")) }
public func isRedisReply(_ b: [UInt8]) -> Bool {
    let s = String(decoding: b.prefix(64), as: UTF8.self)
    return s.hasPrefix("+PONG") || s.hasPrefix("-NOAUTH") || s.hasPrefix("-ERR operation not permitted")
}
public func isMemcachedReply(_ b: [UInt8]) -> Bool { String(decoding: b.prefix(32), as: UTF8.self).hasPrefix("VERSION ") }
/// AMQP servers answer Connection.Start (frame type 1, channel 0) or their own protocol header.
public func isAMQPReply(_ b: [UInt8]) -> Bool { (b.count >= 7 && b[0] == 1 && b[1] == 0 && b[2] == 0) || b.starts(with: Array("AMQP".utf8)) }
/// An OP_MSG (2013) or OP_REPLY (1) header answering our request id 1.
public func isMongoReply(_ b: [UInt8]) -> Bool {
    guard b.count >= 16 else { return false }
    func le(_ i: Int) -> Int32 { b[i..<i + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian }
    return le(8) == 1 && (le(12) == 2013 || le(12) == 1)
}
/// MySQL/MariaDB speak first: [3-byte length][seq 0][protocol 10][version…\0].
public func isMySQLGreeting(_ b: [UInt8]) -> Bool {
    guard b.count > 6, b[3] == 0, b[4] == 10 else { return false }
    return b[5...].prefix(32).contains(0) && b[5] >= UInt8(ascii: "0") && b[5] <= UInt8(ascii: "9")
}

public let databaseProbeTimeout: TimeInterval = 0.3      // each handshake
public let databaseProbeBudget: TimeInterval = 0.8       // all handshakes of one listener

/// Worth a handshake: an unknown loopback-reachable listener of yours above 1023, never one already known
/// as a database, never a system process, never one that answered HTTP.
public func isDatabaseProbeCandidate(_ l: Listener, uid: uid_t = getuid()) -> Bool {
    if case .specific = l.exposure { return false }
    return l.uid == uid && l.port > 1023 && !l.stopped && l.web == nil && knownDatabase(l) == nil
        && [.backend, .service, .docker].contains(l.baseKind)
}

/// Try each handshake on loopback within the budget; the first protocol that answers correctly wins.
public func probeDatabase(_ l: Listener, budget: TimeInterval = databaseProbeBudget,
                          each: TimeInterval = databaseProbeTimeout) -> DatabaseType? {
    guard isDatabaseProbeCandidate(l) else { return nil }
    let end = Date().addingTimeInterval(budget)
    func ask(_ payload: [UInt8]) -> [UInt8] {
        let d = min(end, Date().addingTimeInterval(each))
        for host in ["127.0.0.1", "::1"] {
            if let r = exchange(host: host, port: l.port, payload: payload, deadline: d) { return r }
        }
        return []
    }
    if isPostgresReply(ask(pgSSLRequest)) { return .postgres }
    if Date() >= end { return nil }
    if isRedisReply(ask(redisPing)) { return .redis }
    if Date() >= end { return nil }
    if isMySQLGreeting(ask([])) { return .mysql }                  // server-first: send nothing, read the greeting
    if Date() >= end { return nil }
    if isMongoReply(ask(mongoHello)) { return .mongodb }
    if Date() >= end { return nil }
    if isMemcachedReply(ask(memcachedVersion)) { return .memcached }
    if Date() >= end { return nil }
    if isAMQPReply(ask(amqpHeader)) { return .amqp }
    return nil
}

/// Handshake results per listener instance (pid + start + port), pruned to live listeners. Thread-safe.
public final class DatabaseProbeCache: @unchecked Sendable {
    public static let shared = DatabaseProbeCache()
    private let lock = NSLock()
    private var known: [String: DatabaseType?] = [:]
    private let probe: @Sendable (Listener) -> DatabaseType?
    public init(probe: @escaping @Sendable (Listener) -> DatabaseType? = { probeDatabase($0) }) { self.probe = probe }

    /// Fill `probedDatabase` from the cache; with `probe`, handshake candidates not seen before (in parallel).
    public func apply(_ ls: [Listener], probe: Bool) -> [Listener] {
        if probe {
            lock.lock(); let todo = ls.filter { isDatabaseProbeCandidate($0) && known[listenerKey($0)] == nil }; lock.unlock()
            var found = [DatabaseType?](repeating: nil, count: todo.count)
            found.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: todo.count) { out[$0] = self.probe(todo[$0]) }
            }
            lock.lock(); for (l, t) in zip(todo, found) { known[listenerKey(l)] = .some(t) }; lock.unlock()
        }
        lock.lock(); defer { lock.unlock() }
        let live = Set(ls.map(listenerKey))
        known = known.filter { live.contains($0.key) }
        return ls.map { var l = $0; l.probedDatabase = known[listenerKey($0)] ?? nil; return l }
    }
}

// MARK: - Connecting

/// Host a client should use: 127.0.0.1 for loopback/all-interfaces (avoids localhost → ::1 surprises), else the bound IP.
func clientHost(_ l: Listener) -> String {
    if case .specific(let ip) = l.exposure { return ip.contains(":") ? "[\(ip)]" : ip }
    return l.addresses.allSatisfy({ $0.contains(":") }) ? "[::1]" : "127.0.0.1"
}

/// postgres://127.0.0.1:5432 and friends. No user or password is ever filled in.
public func connectionURL(_ t: DatabaseType, _ l: Listener) -> URL? {
    t.scheme.flatMap { URL(string: "\($0)://\(clientHost(l)):\(l.port)") }
}

/// The matching CLI command (`psql`, `mysql`, `redis-cli`, `mongosh`, …).
public func cliCommand(_ t: DatabaseType, _ l: Listener) -> String? {
    let h = clientHost(l).trimmingCharacters(in: CharacterSet(charactersIn: "[]")), p = l.port
    switch t {
    case .postgres: return "psql -h \(h) -p \(p)"
    case .mysql: return "mysql -h \(h) -P \(p)"
    case .redis: return "redis-cli -h \(h) -p \(p)"
    case .mongodb: return "mongosh \"mongodb://\(clientHost(l)):\(p)\""
    case .memcached: return "nc \(h) \(p)"
    case .clickhouse: return "clickhouse-client --host \(h) --port \(p)"
    default: return nil
    }
}

/// Known clients, preferred in this order when several can open the URL (bundle names).
public let preferredDatabaseClients = ["TablePlus", "Postico 2", "Postico", "pgAdmin 4", "DBeaver", "DataGrip", "Sequel Ace",
                                       "MySQLWorkbench", "MongoDB Compass", "Redis Insight", "RedisInsight", "Beekeeper Studio"]

/// Order candidate app paths: the remembered one first, then known clients, then the rest.
public func rankClients(_ apps: [String], remembered: String?) -> [String] {
    func rank(_ path: String) -> Int {
        if path == remembered { return -1 }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return preferredDatabaseClients.firstIndex(of: name) ?? preferredDatabaseClients.count
    }
    return apps.sorted { (rank($0), $0) < (rank($1), $1) }
}
