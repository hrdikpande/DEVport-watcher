import Darwin
import Foundation
import Testing
@testable import PortsCore

// MARK: - Helpers

/// A loopback/any/specific TCP listener owned by the test process.
final class TestListener {
    let fd: Int32
    let port: Int

    init(ipv4 address: String = "127.0.0.1", port requested: Int = 0) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(requested).bigEndian
        a.sin_addr = in_addr(s_addr: inet_addr(address))
        let ok = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok, listen(fd, 8) == 0 else { Darwin.close(fd); throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.fd = fd
        port = Int(UInt16(bigEndian: a.sin_port))
    }

    /// Answer each connection with `reply` (after reading the request), on a background thread.
    func serve(_ reply: [UInt8]) {
        let fd = self.fd
        Thread.detachNewThread {
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { return }
                var buf = [UInt8](repeating: 0, count: 1024)
                _ = recv(c, &buf, buf.count, 0)
                if !reply.isEmpty { _ = reply.withUnsafeBytes { send(c, $0.baseAddress, reply.count, 0) } }
                Darwin.close(c)
            }
        }
    }

    deinit { Darwin.close(fd) }
}

/// First non-loopback IPv4 address of this Mac, if any.
func firstLANAddress() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return nil }
    defer { freeifaddrs(head) }
    var p = head
    while let i = p {
        defer { p = i.pointee.ifa_next }
        guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
              i.pointee.ifa_flags & UInt32(IFF_UP) != 0, i.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        return String(cString: inet_ntoa(addr))
    }
    return nil
}

func spawn(_ path: String, _ args: [String]) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    return p
}

func waitFor(_ seconds: Double = 2, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if condition() { return true }; usleep(20_000) }
    return condition()
}

func fixture(_ exe: String, _ command: String, port: Int = 4000, uid: uid_t = 501,
             kind: Kind = .system, container: String? = nil) -> Listener {
    Listener(port: port, pid: 1234, start: 1, uid: uid, exposed: false, exe: exe,
             command: command, cwd: "/tmp/project", container: container, kind: kind)
}

// MARK: - 1. Exposure

@Suite("Phase 1 · Exposure")
struct ExposureTests {
    @Test("IPv4 addresses map to the right exposure", arguments: [
        ("0.0.0.0", Exposure.allInterfaces),
        ("127.0.0.1", .loopback),
        ("127.0.0.2", .loopback),
        ("192.168.1.20", .specific("192.168.1.20")),
        ("10.0.0.5", .specific("10.0.0.5")),
    ])
    func ipv4(_ ip: String, _ expected: Exposure) {
        #expect(Exposure(ipv4: in_addr(s_addr: inet_addr(ip))) == expected)
    }

    @Test("IPv6 addresses map to the right exposure", arguments: [
        ("::", Exposure.allInterfaces),
        ("::1", .loopback),
        ("::ffff:127.0.0.1", .loopback),
        ("::ffff:192.168.1.20", .specific("192.168.1.20")),
        ("fe80::1", .specific("fe80::1")),
    ])
    func ipv6(_ ip: String, _ expected: Exposure) {
        var a = in6_addr()
        #expect(inet_pton(AF_INET6, ip, &a) == 1)
        #expect(Exposure(ipv6: a) == expected)
    }

    @Test("Specific non-loopback IP counts as network-reachable; widest bind wins")
    func reachability() {
        #expect(Exposure.specific("192.168.1.20").isNetworkReachable)
        #expect(!Exposure.loopback.isNetworkReachable)
        #expect(Exposure.loopback.widest(.specific("10.0.0.1")) == .specific("10.0.0.1"))
        #expect(Exposure.specific("10.0.0.1").widest(.allInterfaces) == .allInterfaces)
        #expect(Exposure.specific("10.0.0.1").address == "10.0.0.1")
    }

    @Test("Real socket bound to a LAN address is reported as that address")
    func realSpecificBind() throws {
        guard let ip = firstLANAddress() else { return }    // no network interface: nothing to check
        let s = try TestListener(ipv4: ip)
        let match = try #require(Proc.listeningPorts(getpid()).first { $0.port == s.port })
        #expect(match.exposure == .specific(ip))
        #expect(match.exposed)
    }
}

// MARK: - 2. Classifier

struct ClassifyCase: Sendable, CustomStringConvertible {
    let exe: String
    let argv: [String]
    let kind: Kind
    let tool: String
    var description: String { argv.joined(separator: " ") }
}

@Suite("Phase 1 · Classifier")
struct ClassifierTests {
    @Test("Tool comes from exe, argv[0], script, module, node_modules, npx or subcommand", arguments: [
        ClassifyCase(exe: "/usr/local/bin/node", argv: ["node", "/tmp/project/node_modules/.bin/vite"], kind: .frontend, tool: "vite"),
        ClassifyCase(exe: "/usr/local/bin/node", argv: ["node", "/tmp/project/node_modules/next/dist/bin/next", "dev"], kind: .frontend, tool: "next"),
        ClassifyCase(exe: "/usr/local/bin/node", argv: ["node", "/tmp/project/node_modules/@storybook/cli/bin/index.js"], kind: .backend, tool: "node"),
        ClassifyCase(exe: "/usr/local/bin/node", argv: ["npx", "vite@5", "--port", "5173"], kind: .frontend, tool: "vite"),
        ClassifyCase(exe: "/usr/local/bin/node", argv: ["pnpm", "exec", "astro", "dev"], kind: .frontend, tool: "astro"),
        ClassifyCase(exe: "/usr/bin/python3", argv: ["python3", "-m", "uvicorn", "app:app"], kind: .backend, tool: "uvicorn"),
        ClassifyCase(exe: "/usr/bin/python3", argv: ["python3", "manage.py", "runserver"], kind: .backend, tool: "manage.py"),
        ClassifyCase(exe: "/usr/local/bin/uv", argv: ["uv", "run", "uvicorn", "main:app"], kind: .backend, tool: "uvicorn"),
        ClassifyCase(exe: "/usr/local/bin/node", argv: ["node", "-r", "ts-node/register", "server.ts"], kind: .backend, tool: "node"),
        ClassifyCase(exe: "/usr/bin/java", argv: ["java", "-cp", "/opt/kafka/libs/*", "kafka.Kafka", "server.properties"], kind: .database, tool: "kafka"),
        ClassifyCase(exe: "/usr/local/bin/node", argv: ["node", "kafka-consumer.js"], kind: .backend, tool: "node"),
        ClassifyCase(exe: "/usr/local/bin/node", argv: ["next-server (v14.2.3)"], kind: .frontend, tool: "next"),
        ClassifyCase(exe: "/usr/bin/python3", argv: ["python3", "serve.py"], kind: .backend, tool: "python3"),
        ClassifyCase(exe: "/usr/local/bin/node", argv: ["node", "serve.js"], kind: .frontend, tool: "serve"),
        // Folder names must not leak into the result.
        ClassifyCase(exe: "/usr/local/bin/node", argv: ["node", "/tmp/vite-playground/server.js"], kind: .backend, tool: "node"),
        ClassifyCase(exe: "/usr/bin/python3", argv: ["python3", "/tmp/postgres-tools/api.py"], kind: .backend, tool: "python3"),
        ClassifyCase(exe: "/tmp/next-app/bin/server", argv: ["/tmp/next-app/bin/server"], kind: .system, tool: "server"),
    ])
    func identity(_ c: ClassifyCase) {
        let l = Listener(port: 4000, pid: 1234, start: 1, uid: 501, exposed: false, exe: c.exe,
                         command: c.argv.joined(separator: " "), argv: c.argv, cwd: "/tmp/project")
        let (kind, tool) = classify(l)
        #expect(kind == c.kind, "\(c)")
        #expect(tool == c.tool, "\(c)")
    }

    @Test("Script name helpers")
    func helpers() {
        #expect(scriptName("/a/node_modules/.bin/vite") == "vite")
        #expect(scriptName("/a/node_modules/@scope/pkg/bin.js") == "pkg")
        #expect(scriptName("/a/astro-dashboard/app.py") == "app.py")
        #expect(packageName("@scope/tool@1.2") == "tool")
        #expect(firstOperand(["-e", "code"]) == nil)
    }
}

// MARK: - 3 & 4. Container runtimes and labels

@Suite("Phase 1 · Containers")
struct ContainerTests {
    @Test("Container runtime proxies are recognised", arguments: [
        ("/Applications/Docker.app/Contents/Resources/bin/com.docker.backend", "Docker"),
        ("/Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper", "OrbStack"),
        ("/opt/homebrew/Cellar/lima/1.0.0/bin/limactl", "Colima/Lima"),
        ("/Applications/Rancher Desktop.app/Contents/Resources/resources/darwin/lima/bin/limactl", "Rancher Desktop"),
        ("/opt/homebrew/Cellar/podman/5.0.0/libexec/podman/gvproxy", "Podman"),
    ])
    func runtimes(_ exe: String, _ name: String) {
        #expect(containerRuntime(exe: exe) == name)
        #expect(classify(fixture(exe, basename(exe))).0 == .docker)
    }

    @Test("Native processes are not container runtimes")
    func native() {
        #expect(containerRuntime(exe: "/usr/bin/python3") == nil)
        #expect(containerRuntime(exe: "/opt/homebrew/bin/postgres") == nil)
    }

    @Test("CLI lookup includes OrbStack, Rancher Desktop and Podman")
    func cliPaths() {
        #expect(containerCLIPaths.contains(home + "/.orbstack/bin/docker"))
        #expect(containerCLIPaths.contains(home + "/.rd/bin/docker"))
        #expect(containerCLIPaths.contains("/opt/homebrew/bin/podman"))
    }

    @Test("Container query is gated on a runtime proxy, not on Docker Desktop's kind")
    func gate() {
        let orb = fixture("/Applications/OrbStack.app/Contents/MacOS/OrbStack Helper", "OrbStack Helper")
        let py = fixture("/usr/bin/python3", "python3 app.py")
        #expect(!needsContainerQuery([py]))
        #expect(needsContainerQuery([py, orb]) == (dockerPath != nil))
    }

    @Test("Only a runtime proxy gets a container label; a native process on a reused port does not")
    func labels() {
        let map = [8080: "web"]
        #expect(containerName(exe: "/Applications/Docker.app/Contents/Resources/bin/com.docker.backend", port: 8080, docker: map) == "web")
        #expect(containerName(exe: "/usr/bin/python3", port: 8080, docker: map) == nil)
        #expect(containerName(exe: "/Applications/Docker.app/Contents/Resources/bin/com.docker.backend", port: 9090, docker: map) == nil)
    }

    @Test("Docker ports parser is shared with the real query")
    func parser() {
        #expect(parseDockerPorts("web\t0.0.0.0:8080->80/tcp\n") == [8080: "web"])
    }

    @Test("Scan with a stale map never labels this (native) test process")
    func scanIgnoresStaleMap() throws {
        let s = try TestListener()
        let mine = scan(docker: [s.port: "stale"]).filter { $0.pid == getpid() && $0.port == s.port }
        #expect(mine.count == 1)
        #expect(mine.allSatisfy { $0.container == nil && $0.kind != .docker })
    }
}

// MARK: - 6. Process state

@Suite("Phase 1 · Process state")
struct ProcessStateTests {
    @Test("kinfo_proc reports a suspended process; the ladder resumes and stops it")
    func stoppedProcess() throws {
        let child = try spawn("/bin/sleep", ["30"])
        defer { if child.isRunning { child.terminate() } }
        let pid = child.processIdentifier
        #expect(!Proc.isStopped(pid))

        kill(pid, SIGSTOP)
        #expect(waitFor { Proc.isStopped(pid) })

        let id = try #require(Proc.identity(pid))
        #expect(safeTerminate(pid: pid, start: id.start) == nil)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)     // exited on SIGTERM after SIGCONT, not SIGKILL
    }
}

// MARK: - 7. Safety tiers

@Suite("Phase 1 · Safety tiers")
struct SafetyTierTests {
    @Test("Databases and brokers get 15 s, a warning and no automatic SIGKILL")
    func tiers() {
        let db = StopPolicy(fixture("/opt/homebrew/bin/postgres", "postgres", kind: .database))
        let dev = StopPolicy(fixture("/usr/local/bin/node", "node server.js", kind: .backend))
        #expect(db == .dataStore && db.grace == 15 && !db.autoForce && db.warning?.contains("data") == true)
        #expect(dev == .devServer && dev.grace == 2 && dev.autoForce && dev.warning == nil)
    }

    @Test("Without escalation a process ignoring SIGTERM survives; Force is a separate step")
    func noAutoForce() throws {
        let child = try spawn("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 30"])
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        let pid = child.processIdentifier
        usleep(200_000)                                               // let sh exec sleep
        let id = try #require(Proc.identity(pid))

        #expect(safeTerminate(pid: pid, start: id.start, grace: 0.3, escalate: false) == nil)
        #expect(Proc.identity(pid)?.start == id.start)                // still running

        #expect(forceKill(pid: pid, start: id.start) == nil)
        child.waitUntilExit()
        #expect(child.terminationStatus == SIGKILL)
    }

    @Test("Force re-checks identity")
    func forceGuards() {
        #expect(forceKill(pid: getpid(), start: 0) == .protected)
        #expect(forceKill(pid: getpid() + 100_000, start: 0) == .gone)
    }
}

// MARK: - 5 & 8. Owners and post-stop report

@Suite("Phase 1 · Owners and report")
struct OwnerReportTests {
    @Test("Report says free or names who still listens")
    func report() {
        var l = fixture("/usr/local/bin/node", "node server.js", port: 3000)
        l.label = "node · web"
        #expect(portReport(3000, owners: []) == "Port 3000 is free")
        #expect(portReport(3000, owners: [l]) == "Still listening: node · web (PID 1234)")
        #expect(portReport(4000, owners: [l]) == "Port 4000 is free")
    }

    @Test("A fresh scan finds every owner of a port")
    func multipleOwners() throws {
        // Two processes on one port: this test process on IPv4 loopback, a child on IPv6 loopback.
        let s = try TestListener()
        let child = try spawn("/usr/bin/nc", ["-6", "-l", "::1", "\(s.port)"])
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        _ = waitFor { Proc.listeningPorts(child.processIdentifier).contains { $0.port == s.port } }

        let found = owners(ofPort: s.port, in: scanWithContainers())
        #expect(found.map(\.pid).contains(getpid()))
        #expect(found.map(\.pid).contains(child.processIdentifier))
        #expect(found.count == 2)
        #expect(portReport(s.port, owners: found).hasPrefix("Still listening: "))
    }
}

// MARK: - 9. System processes on dev ports

@Suite("Phase 1 · Known ports")
struct KnownPortsTests {
    let controlCenter = "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"

    @Test("ControlCenter on 5000/7000 is shown in Developer view as AirPlay Receiver", arguments: [5000, 7000])
    func airPlay(_ port: Int) throws {
        let l = fixture(controlCenter, "ControlCenter", port: port, uid: 501, kind: .system)
        let why = try #require(KnownPorts.explanation(l))
        #expect(why.contains("AirPlay Receiver"))
        #expect(why.contains("turn off"))
        #expect(showsInDeveloperView(l))
    }

    @Test("Any system process on a common dev port is shown; elsewhere it stays in System & Apps")
    func otherSystem() {
        let onDevPort = fixture("/usr/libexec/rapportd", "rapportd", port: 3000, uid: 0, kind: .system)
        let elsewhere = fixture("/usr/libexec/rapportd", "rapportd", port: 53943, uid: 0, kind: .system)
        #expect(showsInDeveloperView(onDevPort))
        #expect(KnownPorts.explanation(onDevPort)?.contains("3000") == true)
        #expect(!showsInDeveloperView(elsewhere))
        #expect(KnownPorts.explanation(elsewhere) == nil)
    }
}

// MARK: - 10. Open in Browser

@Suite("Phase 1 · Web probe")
struct WebProbeTests {
    @Test("Reply bytes decide http, https or neither")
    func replies() {
        #expect(webScheme(fromReply: Array("HTTP/1.1 200 OK\r\n".utf8)) == .http)
        #expect(webScheme(fromReply: Array("HTTP/1.1 400 Bad Request\r\n\r\nThe plain HTTP request was sent to HTTPS port".utf8)) == .https)
        #expect(webScheme(fromReply: [0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x46]) == .https)
        #expect(webScheme(fromReply: [0x16, 0x03, 0x03, 0x00, 0x40]) == .https)
        #expect(webScheme(fromReply: Array("-ERR unknown command 'HEAD'\r\n".utf8)) == nil)
        #expect(webScheme(fromReply: []) == nil)
        #expect(tlsProbe.count == 5 + 0x33)
    }

    func probe(_ reply: [UInt8]) throws -> WebScheme? {
        let server = try TestListener()
        server.serve(reply)
        let l = Listener(port: server.port, pid: getpid(), start: 1, uid: getuid(), exposed: false,
                         exe: "/usr/local/bin/node", command: "node server.js", cwd: "/tmp", kind: .backend)
        return probeWeb(l)
    }

    @Test("Real loopback servers: HTTP, TLS, silent, non-HTTP")
    func servers() throws {
        #expect(try probe(Array("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)) == .http)
        #expect(try probe([0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x46]) == .https)
        #expect(try probe([]) == nil)
        #expect(try probe(Array("-ERR unknown\r\n".utf8)) == nil)
    }

    @Test("Only dev servers and containers are probed; URL uses the real address")
    func candidates() {
        var l = fixture("/usr/local/bin/vite", "vite", port: 5173, kind: .frontend)
        #expect(isWebCandidate(l))
        #expect(browserURL(l, .https)?.absoluteString == "https://localhost:5173")
        l.exposure = .specific("192.168.1.20")
        #expect(browserURL(l, .http)?.absoluteString == "http://192.168.1.20:5173")
        l.exposure = .specific("fe80::1")
        #expect(browserURL(l, .http)?.absoluteString == "http://[fe80::1]:5173")
        l.stopped = true
        #expect(!isWebCandidate(l))
        #expect(!isWebCandidate(fixture("/opt/homebrew/bin/postgres", "postgres", port: 5432, kind: .database)))
        #expect(!isWebCandidate(fixture("/usr/libexec/rapportd", "rapportd", kind: .system)))
    }
}
