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
