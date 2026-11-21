import Darwin
import Foundation
import Testing
@testable import PortsCore

extension TestListener {
    /// Server-first protocols (MySQL): send `bytes` as soon as a client connects, then close.
    func serveFirst(_ bytes: [UInt8]) {
        let fd = self.fd
        Thread.detachNewThread {
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { return }
                _ = bytes.withUnsafeBytes { send(c, $0.baseAddress, bytes.count, 0) }
                Darwin.close(c)
            }
        }
    }
}

func unknownListener(port: Int, uid: uid_t = getuid(), kind: Kind = .backend, exposure: Exposure = .loopback) -> Listener {
    Listener(port: port, pid: getpid(), start: 1, uid: uid, exposed: exposure.isNetworkReachable, exposure: exposure,
             exe: "/opt/demo/bin/mystery", command: "mystery", cwd: "/tmp", kind: kind)
}

func mongoReply() -> [UInt8] {
    func le32(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    return le32(21) + le32(99) + le32(1) + le32(2013) + [0, 0, 0, 0, 0]
}
let mysqlGreeting: [UInt8] = [0x4a, 0, 0, 0, 10] + Array("8.0.36".utf8) + [0, 1, 0, 0, 0]

@Suite("Phase 7 · Database detection")
struct DatabaseDetectionTests {
    @Test("From the process table and from container images", arguments: [
        ("PostgreSQL", Optional(DatabaseType.postgres)), ("MariaDB", .mysql), ("Valkey", .redis), ("MongoDB", .mongodb),
        ("RabbitMQ", .amqp), ("Neo4j", .other), ("Vite", nil),
    ] as [(String, DatabaseType?)])
    func frameworks(name: String, expected: DatabaseType?) { #expect(databaseType(framework: name) == expected) }

    @Test("Container images", arguments: [
        ("postgres:16", Optional(DatabaseType.postgres)), ("bitnami/redis:7.2", .redis), ("mysql/mysql-server", .mysql),
        ("mongo", .mongodb), ("mcr.microsoft.com/mssql/server:2022", .other), ("nginx:1.27", nil),
    ] as [(String, DatabaseType?)])
    func images(image: String, expected: DatabaseType?) { #expect(databaseType(image: image) == expected) }

    @Test("Where a database was recognised")
    func sources() {
        var proc = unknownListener(port: 5432, kind: .database)
        proc.framework = "PostgreSQL"
        #expect(knownDatabase(proc)?.1 == .process)
        var img = unknownListener(port: 55432, kind: .docker)
        img.containerInfo = ContainerInfo(id: "a", name: "db", image: "postgres:16", state: "running", status: "", project: nil,
                                          service: nil, ports: [], runtime: nil)
        #expect(knownDatabase(img)?.0 == .postgres && knownDatabase(img)?.1 == .image)
        #expect(!isWebCandidate(img))                                 // a database container is never web-probed
        var shake = unknownListener(port: 6380)
        shake.probedDatabase = .redis
        #expect(knownDatabase(shake)?.1 == .handshake)
        #expect(knownDatabase(unknownListener(port: 9999)) == nil)
    }
}

@Suite("Phase 7 · Handshakes")
struct HandshakeTests {
    @Test("Reply parsers accept their protocol and reject the others")
    func parsers() {
        let replies: [String: [UInt8]] = ["pg": Array("N".utf8), "redis": Array("+PONG\r\n".utf8),
                                          "memcached": Array("VERSION 1.6.21\r\n".utf8), "amqp": Array("AMQP".utf8) + [0, 0, 9, 1],
                                          "mongo": mongoReply(), "mysql": mysqlGreeting, "http": Array("HTTP/1.1 400 Bad\r\n\r\n".utf8)]
        let checks: [String: ([UInt8]) -> Bool] = ["pg": isPostgresReply, "redis": isRedisReply, "memcached": isMemcachedReply,
                                                   "amqp": isAMQPReply, "mongo": isMongoReply, "mysql": isMySQLGreeting]
        for (proto, check) in checks {
            for (name, reply) in replies { #expect(check(reply) == (name == proto), "\(proto) vs \(name)") }
        }
        #expect(isRedisReply(Array("-NOAUTH Authentication required.\r\n".utf8)))
        #expect(isPostgresReply(Array("S".utf8)))
        #expect(!isPostgresReply([]))
    }

    @Test("The Mongo hello is a well-formed OP_MSG with no credentials")
    func mongoMessage() {
        let len = mongoHello[0..<4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
        let op = mongoHello[12..<16].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
        #expect(Int(len) == mongoHello.count && op == 2013)
        let text = String(decoding: mongoHello, as: UTF8.self)
        #expect(text.contains("hello") && !text.lowercased().contains("pass") && !text.contains("saslStart"))
        #expect(pgSSLRequest == [0, 0, 0, 8, 4, 210, 22, 47])
    }

    @Test("Real loopback servers are recognised", arguments: [
        ("postgres", DatabaseType.postgres), ("redis", .redis), ("memcached", .memcached), ("amqp", .amqp), ("mongo", .mongodb),
        ("mysql", .mysql),
    ])
    func servers(kind: String, expected: DatabaseType) throws {
        let s = try TestListener()
        switch kind {
        case "postgres": s.serve(Array("N".utf8))
        case "redis": s.serve(Array("+PONG\r\n".utf8))
        case "memcached": s.serve(Array("VERSION 1.6.21\r\n".utf8))
        case "amqp": s.serve(Array("AMQP".utf8) + [0, 0, 9, 1])
        case "mongo": s.serve(mongoReply())
        default: s.serveFirst(mysqlGreeting)
        }
        // A generous test budget: the test server answers from a background thread that may run late under load.
        #expect(probeDatabase(unknownListener(port: s.port), budget: 10, each: 2) == expected)
    }

    @Test("An HTTP server and a silent server are not databases; silence costs about the budget")
    func negatives() throws {
        let http = try TestListener()
        http.serve(Array("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n".utf8))
        #expect(probeDatabase(unknownListener(port: http.port), budget: 10, each: 2) == nil)
        let silent = try TestListener()
        let t0 = Date()
        #expect(probeDatabase(unknownListener(port: silent.port)) == nil)
        #expect(Date().timeIntervalSince(t0) < 2 * databaseProbeBudget)
    }

    @Test("Who gets a handshake", arguments: [
        (unknownListener(port: 6380), true),
        (unknownListener(port: 6380, uid: getuid() + 1), false),                    // someone else's
        (unknownListener(port: 6380, kind: .database), false),                     // never Databases kind (already known)
        (unknownListener(port: 6380, kind: .system), false),
        (unknownListener(port: 6380, kind: .app), false),
        (unknownListener(port: 631), false),                                       // privileged
        (unknownListener(port: 6380, exposure: .specific("192.168.1.20")), false), // LAN-only: not on loopback
    ] as [(Listener, Bool)])
    func candidates(l: Listener, expected: Bool) { #expect(isDatabaseProbeCandidate(l) == expected) }

    @Test("Probe cache: nothing is probed unless asked; results are pruned to live listeners")
    func cache() {
        let calls = ProbeCalls()
        let c = DatabaseProbeCache(probe: { _ in calls.bump(); return .redis })
        let l = unknownListener(port: 6380)
        #expect(c.apply([l], probe: false)[0].probedDatabase == nil)
        #expect(calls.value == 0)                                                  // closed menu: never probed
        #expect(c.apply([l], probe: true)[0].probedDatabase == .redis)
        #expect(c.apply([l], probe: true)[0].probedDatabase == .redis)
        #expect(calls.value == 1)                                                  // remembered, not probed again
        #expect(c.apply([l], probe: false)[0].probedDatabase == .redis)
        #expect(c.apply([], probe: false).isEmpty)
        #expect(c.apply([l], probe: false)[0].probedDatabase == nil)               // pruned while it was gone
    }
}

final class ProbeCalls: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite("Phase 7 · Connecting")
struct ConnectingTests {
    @Test("Connection URLs and CLI commands never carry credentials")
    func urls() {
        var l = unknownListener(port: 5432)
        l.addresses = ["127.0.0.1", "::1"]
        #expect(connectionURL(.postgres, l)?.absoluteString == "postgres://127.0.0.1:5432")
        #expect(cliCommand(.postgres, l) == "psql -h 127.0.0.1 -p 5432")
        var v6 = unknownListener(port: 6379); v6.addresses = ["::1"]
        #expect(connectionURL(.redis, v6)?.absoluteString == "redis://[::1]:6379")
        #expect(cliCommand(.redis, v6) == "redis-cli -h ::1 -p 6379")
        let lan = unknownListener(port: 3306, exposure: .specific("192.168.1.20"))
        #expect(connectionURL(.mysql, lan)?.absoluteString == "mysql://192.168.1.20:3306")
        #expect(cliCommand(.mysql, lan) == "mysql -h 192.168.1.20 -P 3306")
        #expect(cliCommand(.mongodb, l) == #"mongosh "mongodb://127.0.0.1:5432""#)
        #expect(connectionURL(.memcached, l) == nil)
        #expect(connectionURL(.amqp, l)?.scheme == "amqp")
    }

    @Test("Clients: the remembered one first, then known clients, then the rest")
    func ranking() {
        let apps = ["/Applications/Zeta.app", "/Applications/DBeaver.app", "/Applications/TablePlus.app"]
        #expect(rankClients(apps, remembered: nil) == ["/Applications/TablePlus.app", "/Applications/DBeaver.app", "/Applications/Zeta.app"])
        #expect(rankClients(apps, remembered: "/Applications/Zeta.app").first == "/Applications/Zeta.app")
    }

    @Test("The chosen client is remembered per database type; older settings still load")
    func remembered() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ports-p7-\(UUID().uuidString)/settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try SettingsStore(url: url).update { $0.databaseClients["postgres"] = "/Applications/TablePlus.app" }
        #expect(SettingsStore(url: url).settings.databaseClients["postgres"] == "/Applications/TablePlus.app")
        #expect(try JSONDecoder().decode(Settings.self, from: Data(#"{"protectedPorts":[5432]}"#.utf8)).databaseClients.isEmpty)
    }

    @Test("A database found by handshake that listens on the network is a critical Doctor issue")
    func exposure() {
        var l = unknownListener(port: 6380, exposure: .allInterfaces)
        l.addresses = ["0.0.0.0"]
        l.probedDatabase = .redis
        let issue = diagnose([l], Analysis(), DoctorInput()).first { $0.id.hasPrefix("dbexposed") }
        #expect(issue?.severity == .critical)
        #expect(issue?.title.contains("Redis") == true)
    }
}
