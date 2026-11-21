import Darwin
import Foundation
import Testing
@testable import PortsCore

func engineFixture() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "engine-containers", withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// A fake Engine API on a unix socket in a temp folder: answers every request with a fixed response and
/// records the request lines. Never serves files.
final class FakeEngine: @unchecked Sendable {
    let dir: String
    let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var lines: [String] = []

    /// `accepting: false` listens but never accepts: a connect succeeds and the engine stays silent.
    init(accepting: Bool = true, reply: @escaping @Sendable (String) -> Data) throws {
        dir = "/tmp/ports-p6-\(UUID().uuidString.prefix(8))"           // short: sun_path holds 104 bytes
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/engine.sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let p = path
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in p.utf8.enumerated() { buf[i] = b } }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
        guard ok, listen(fd, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        let fd = self.fd
        guard accepting else { return }
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { return }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = recv(c, &buf, buf.count, 0)
                let line = String(decoding: buf.prefix(max(0, n)), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                self?.record(line)
                let out = reply(line)
                _ = out.withUnsafeBytes { send(c, $0.baseAddress, out.count, 0) }
                Darwin.close(c)
            }
        }
    }
    private func record(_ l: String) { lock.lock(); lines.append(l); lock.unlock() }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    deinit { Darwin.close(fd); try? FileManager.default.removeItem(atPath: dir) }
}

func http(_ status: Int, _ body: Data, chunked: Bool = false) -> Data {
    var head = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\n"
    if chunked {
        head += "Transfer-Encoding: chunked\r\n\r\n"
        var d = Data(head.utf8)
        for part in [body.prefix(body.count / 2), body.dropFirst(body.count / 2)] where !part.isEmpty {
            d.append(Data(String(part.count, radix: 16).utf8) + Data("\r\n".utf8) + part + Data("\r\n".utf8))
        }
        return d + Data("0\r\n\r\n".utf8)
    }
    return Data((head + "Content-Length: \(body.count)\r\n\r\n").utf8) + body
}

func proxy(port: Int, pid: pid_t = 777) -> Listener {
    Listener(port: port, pid: pid, start: 1, uid: getuid(), exposed: true, exposure: .allInterfaces,
             exe: "/opt/homebrew/bin/gvproxy", command: "gvproxy", cwd: "/")
}

@Suite("Phase 6 · Runtime locator")
struct LocatorTests {
    @Test("DOCKER_HOST accepts only local unix sockets", arguments: [
        ("unix:///tmp/demo/docker.sock", Optional("/tmp/demo/docker.sock")), ("tcp://127.0.0.1:2375", nil),
        ("unix://relative.sock", nil), ("ssh://demo@host", nil),
    ] as [(String, String?)])
    func dockerHost(value: String, expected: String?) { #expect(unixSocketPath(value) == expected) }

    @Test("Runtimes are named from where their socket lives", arguments: [
        ("/tmp/demo-home/.orbstack/run/docker.sock", "OrbStack", "OrbStack"),
        ("/tmp/demo-home/.colima/work/docker.sock", "Colima (work)", "Colima/Lima"),
        ("/tmp/demo-home/.lima/dev/sock/docker.sock", "Lima (dev)", "Colima/Lima"),
        ("/tmp/demo-home/.rd/docker.sock", "Rancher Desktop", "Rancher Desktop"),
        ("/tmp/demo-home/.local/share/containers/podman/machine/qemu/podman.sock", "Podman", "Podman"),
        ("/tmp/demo-home/.docker/run/docker.sock", "Docker Desktop", "Docker"),
        ("/var/run/docker.sock", "Docker", "Docker"),
    ])
    func naming(socket: String, name: String, family: String) {
        let r = runtimeFor(socket: socket, home: "/tmp/demo-home")
        #expect(r.name == name && r.family == family)
    }

    @Test("Sockets are found in order (DOCKER_HOST, context, …), deduplicated, and only if they are sockets")
    func locate() throws {
        let home = "/tmp/ports-p6h-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        for d in [".orbstack/run", ".colima/work", ".docker/contexts/meta/abc", ".rd"] {
            try fm.createDirectory(atPath: "\(home)/\(d)", withIntermediateDirectories: true)
        }
        var keep: [Int32] = []
        defer { keep.forEach { Darwin.close($0) } }
        func makeSocket(_ path: String) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in path.utf8.enumerated() { buf[i] = b } }
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            keep.append(fd)
        }
        makeSocket("\(home)/.orbstack/run/docker.sock")
        makeSocket("\(home)/.colima/work/docker.sock")
        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: "\(home)/.rd/docker.sock"))
        try fm.createSymbolicLink(atPath: "\(home)/alias.sock", withDestinationPath: "\(home)/.colima/work/docker.sock")
        try Data(#"{"currentContext": "orb"}"#.utf8).write(to: URL(fileURLWithPath: "\(home)/.docker/config.json"))
        try Data(#"{"Name": "orb", "Endpoints": {"docker": {"Host": "unix://\#(home)/.orbstack/run/docker.sock"}}}"#.utf8)
            .write(to: URL(fileURLWithPath: "\(home)/.docker/contexts/meta/abc/meta.json"))
        #expect(currentContextSocket(home: home) == "\(home)/.orbstack/run/docker.sock")

        // Only sockets under the test's home: the Mac's own /var/run/docker.sock may exist too.
        let found = locateRuntimes(home: home, env: ["DOCKER_HOST": "unix://\(home)/alias.sock"], tmp: home + "/tmp")
            .filter { $0.socket.hasPrefix(home) }
        #expect(found.map(\.name) == ["Colima (work)", "OrbStack"])          // alias = colima (first), context = orbstack
        #expect(found[0].socket == "\(home)/alias.sock")
        #expect(locateRuntimes(home: home + "/none", env: [:], tmp: home).isEmpty
                || locateRuntimes(home: home + "/none", env: [:], tmp: home).allSatisfy { $0.socket == "/var/run/docker.sock" })
    }
}

@Suite("Phase 6 · Engine API")
struct EngineTests {
    @Test("HTTP responses: Content-Length, chunked, no body, truncated, garbage")
    func parsing() {
        let body = Data(#"[{"a":1}]"#.utf8)
        #expect(parseHTTPResponse(http(200, body))?.body == body)
        #expect(parseHTTPResponse(http(200, body, chunked: true))?.body == body)
        #expect(parseHTTPResponse(Data("HTTP/1.1 204 No Content\r\n\r\n".utf8))?.status == 204)
        #expect(parseHTTPResponse(http(200, body).dropLast(3)) == nil)
        #expect(parseHTTPResponse(Data("garbage".utf8)) == nil)
        #expect(completeResponse(http(200, body, chunked: true).dropLast(5)) == nil)
    }

    @Test("Containers parse from recorded Engine API JSON")
    func containers() throws {
        let rt = ContainerRuntime(name: "OrbStack", family: "OrbStack", socket: "/tmp/demo.sock")
        let cs = parseContainers(try engineFixture(), runtime: rt)
        #expect(cs.map(\.name) == ["demo-db-1", "demo-web-1", "demo-old", "demo-solo"])   // invalid id dropped
        let db = cs[0]
        #expect(db.image == "postgres:16" && db.project == "demo-shop" && db.service == "db" && db.health == "healthy")
        #expect(db.label == "demo-db-1 · postgres:16 · demo-shop/db · healthy")
        #expect(db.publishedOnAllInterfaces(55432))
        #expect(!cs[1].publishedOnAllInterfaces(58080))
        #expect(cs[1].health == "starting")
        #expect(cs[1].ports.count == 1)                                     // unpublished 9000 skipped
        #expect(cs[3].project == nil && cs[3].label == "demo-solo · demo/api")
        let map = containerMap(cs)
        #expect(Set(map.keys) == [55432, 58080])                            // exited container not mapped
        #expect(parseContainers(Data("{}".utf8)).isEmpty)
    }

    @Test("Only a runtime's proxy gets a container; the matching runtime wins")
    func mapping() throws {
        let orb = ContainerRuntime(name: "OrbStack", family: "OrbStack", socket: "/a")
        let pod = ContainerRuntime(name: "Podman", family: "Podman", socket: "/b")
        let cs = parseContainers(try engineFixture(), runtime: orb) + parseContainers(try engineFixture(), runtime: pod)
        let map = containerMap(cs)
        #expect(containerInfo(exe: "/opt/homebrew/bin/gvproxy", port: 55432, map: map)?.runtime == pod)
        #expect(containerInfo(exe: "/Applications/OrbStack.app/Contents/MacOS/OrbStack Helper", port: 55432, map: map)?.runtime == orb)
        #expect(containerInfo(exe: "/usr/bin/python3", port: 55432, map: map) == nil)          // native process: never
        #expect(containerInfo(exe: "/opt/homebrew/bin/gvproxy", port: 1, map: map) == nil)
    }

    @Test("Client round trip over a unix socket, and container actions as POSTs")
    func roundTrip() throws {
        let body = try engineFixture()
        let engine = try FakeEngine { line in
            if line.hasPrefix("GET /containers/json") { return http(200, body, chunked: true) }
            if line.hasPrefix("POST /containers/") { return Data("HTTP/1.1 204 No Content\r\n\r\n".utf8) }
            return http(404, Data(#"{"message":"no"}"#.utf8))
        }
        let r = try #require(unixHTTP(socket: engine.path, path: "/containers/json"))
        #expect(r.status == 200 && r.body == body)
        let id = "aaaaaaaaaaaa1111111111111111111111111111111111111111111111111111"
        #expect(engineContainerAction("stop", id: id, socket: engine.path) == nil)
        #expect(engineContainerAction("restart", id: id, socket: engine.path) == nil)
        #expect(engine.requests.contains("POST /containers/\(id)/stop?t=10 HTTP/1.1"))
        #expect(engine.requests.contains("POST /containers/\(id)/restart?t=10 HTTP/1.1"))
        #expect(engineContainerAction("remove", id: id, socket: engine.path) != nil)          // only stop/restart
        #expect(engineContainerAction("stop", id: "../../x", socket: engine.path) != nil)
        #expect(unixHTTP(socket: engine.dir + "/missing.sock", path: "/containers/json") == nil)
        #expect(unixHTTP(socket: engine.path, path: "/x y") == nil)                            // no request smuggling
    }

    @Test("A silent engine times out within the budget")
    func timeout() throws {
        let engine = try FakeEngine(accepting: false) { _ in Data() }
        let t0 = Date()
        #expect(unixHTTP(socket: engine.path, path: "/containers/json", timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(t0) < 2 * 0.5 + 1)
    }
}

@Suite("Phase 6 · Container directory")
struct DirectoryTests {
    final class Count: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @Test("Asked only with a proxy listening; cached for maxAge; re-asked when proxies change")
    func cadence() throws {
        let body = try engineFixture()
        let gets = Count()
        let engine = try FakeEngine { line in
            if line.hasPrefix("GET") { gets.bump() }
            return line.hasPrefix("POST") ? Data("HTTP/1.1 204 No Content\r\n\r\n".utf8) : http(200, body)
        }
        let path = engine.path
        let dir = ContainerDirectory(locate: { [ContainerRuntime(name: "Podman", family: "Podman", socket: path)] }, cli: { nil })
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(dir.current(listeners: [dev()], maxAge: 15, now: t0) == nil)              // no proxy: never asked
        #expect(gets.value == 0)
        let snap = try #require(dir.current(listeners: [proxy(port: 55432)], maxAge: 15, now: t0))
        #expect(snap.reachable && snap.answered.count == 1 && snap.containers.count == 4)
        _ = dir.current(listeners: [proxy(port: 55432)], maxAge: 15, now: t0.addingTimeInterval(10))
        #expect(gets.value == 1)                                                          // fresh: cached
        _ = dir.current(listeners: [proxy(port: 55432)], maxAge: 15, now: t0.addingTimeInterval(16))
        #expect(gets.value == 2)                                                          // stale: asked again
        _ = dir.current(listeners: [proxy(port: 55432), proxy(port: 58080, pid: 778)], maxAge: 15, now: t0.addingTimeInterval(17))
        #expect(gets.value == 3)                                                          // proxies changed
        _ = dir.current(listeners: [proxy(port: 55432), proxy(port: 58080, pid: 778)], maxAge: 0, now: t0.addingTimeInterval(17))
        #expect(gets.value == 4)                                                          // open menu: always
        #expect(snap.project("demo-shop").map(\.name) == ["demo-db-1", "demo-web-1"])
        #expect(containerAction("stop", name: "demo-db-1", directory: dir) == nil)
        #expect(engine.requests.contains { $0.hasPrefix("POST /containers/aaaaaaaaaaaa") && $0.contains("/stop") })
        #expect(containerAction("stop", name: "-rf", directory: dir) != nil)
    }

    @Test("No engine answering: unreachable, or the CLI fallback")
    func fallback() {
        let dead = ContainerDirectory(locate: { [ContainerRuntime(name: "Docker", family: "Docker", socket: "/tmp/ports-none.sock")] },
                                      cli: { nil })
        let s1 = dead.current(listeners: [proxy(port: 5432)], maxAge: 0)
        #expect(s1?.reachable == false)
        let cli = ContainerDirectory(locate: { [] }, cli: { [5432: "db"] })
        let s2 = cli.current(listeners: [proxy(port: 5432)], maxAge: 0)
        #expect(s2?.viaCLI == true && s2?.namesByPort == [5432: "db"])
    }

    @Test("Scans label proxy listeners with container details; others stay untouched")
    func scanLabels() throws {
        let s = try TestListener()
        let cs = parseContainers(try engineFixture())
        var map = containerMap(cs)
        map[s.port] = [cs[0]]                                                             // a stale entry on our port
        let mine = try #require(scan(docker: [:], containers: map, cache: ProcessCache()).first { $0.pid == getpid() && $0.port == s.port })
        #expect(mine.container == nil && mine.containerInfo == nil)
    }
}

@Suite("Phase 6 · Compose, exposure, logs")
struct ComposeTests {
    @Test("Compose stop confirmation lists the containers; logs command is quoted")
    func compose() {
        let c = confirmation(.compose(project: "demo-shop", containers: ["demo-db-1", "demo-web-1"]), for: dev())
        #expect(c.whatStops.contains("demo-db-1, demo-web-1"))
        for label in ["What stops:", "How:", "Restarts automatically:", "After next login:"] { #expect(c.text.contains(label)) }
        #expect(logsCommand("demo-db-1") == "docker logs -f demo-db-1")
    }

    @Test("A container published on all interfaces is a Doctor issue (critical for databases)")
    func exposure() throws {
        let cs = parseContainers(try engineFixture())
        var db = proxy(port: 55432); db.container = cs[0].name; db.containerInfo = cs[0]; db.kind = .docker
        var web = proxy(port: 58080, pid: 778); web.container = cs[1].name; web.containerInfo = cs[1]; web.kind = .docker
        let issues = diagnose([db, web], Analysis(), DoctorInput())
        let pub = issues.filter { $0.id.hasPrefix("publish-") }
        #expect(pub.count == 1)
        #expect(pub[0].severity == .critical)
        #expect(pub[0].explanation.contains("127.0.0.1:55432:5432"))
    }

    @Test("Database images", arguments: [("postgres:16", true), ("bitnami/redis:7", true), ("mcr.microsoft.com/mssql/server:2022", true),
                                         ("demo/web:latest", false), ("nginx", false)])
    func images(image: String, db: Bool) { #expect(isDatabaseImage(image) == db) }
}
