import Darwin
import Foundation
import Testing
@testable import PortsCore

extension Tag {
    @Tag static var knownBug: Self
}

struct ClassifierFixture: Sendable {
    let name: String
    let port: Int
    let uid: uid_t
    let exe: String
    let command: String
    let cwd: String
    let container: String?
    let expectedKind: Int
}

private let classifierFixtures: [ClassifierFixture] = [
    // Frontend
    .init(name: "vite", port: 5173, uid: 501, exe: "/usr/local/bin/vite", command: "vite --host", cwd: "/tmp/frontend", container: nil, expectedKind: Kind.frontend.rawValue),
    .init(name: "next", port: 3000, uid: 501, exe: "/usr/local/bin/node", command: "next dev", cwd: "/tmp/frontend", container: nil, expectedKind: Kind.frontend.rawValue),
    .init(name: "astro", port: 4321, uid: 501, exe: "/usr/local/bin/astro", command: "astro dev", cwd: "/tmp/frontend", container: nil, expectedKind: Kind.frontend.rawValue),
    .init(name: "storybook", port: 6006, uid: 501, exe: "/usr/local/bin/storybook", command: "storybook dev -p 6006", cwd: "/tmp/frontend", container: nil, expectedKind: Kind.frontend.rawValue),
    .init(name: "expo", port: 19000, uid: 501, exe: "/usr/local/bin/expo", command: "expo start", cwd: "/tmp/frontend", container: nil, expectedKind: Kind.frontend.rawValue),
    .init(name: "next-server", port: 3001, uid: 501, exe: "/usr/local/bin/next-server", command: "next-server", cwd: "/tmp/frontend", container: nil, expectedKind: Kind.frontend.rawValue),
    .init(name: "http-server", port: 8080, uid: 501, exe: "/usr/local/bin/http-server", command: "http-server ./public", cwd: "/tmp/frontend", container: nil, expectedKind: Kind.frontend.rawValue),

    // Backend
    .init(name: "node", port: 4000, uid: 501, exe: "/usr/local/bin/node", command: "node server.js", cwd: "/tmp/backend", container: nil, expectedKind: Kind.backend.rawValue),
    .init(name: "python", port: 8000, uid: 501, exe: "/usr/bin/python3", command: "python3 app.py", cwd: "/tmp/backend", container: nil, expectedKind: Kind.backend.rawValue),
    .init(name: "uvicorn", port: 8001, uid: 501, exe: "/usr/local/bin/uvicorn", command: "uvicorn app:app", cwd: "/tmp/backend", container: nil, expectedKind: Kind.backend.rawValue),
    .init(name: "rails", port: 3000, uid: 501, exe: "/usr/local/bin/rails", command: "rails server", cwd: "/tmp/backend", container: nil, expectedKind: Kind.backend.rawValue),
    .init(name: "go", port: 8081, uid: 501, exe: "/usr/local/bin/go", command: "go run ./cmd/server", cwd: "/tmp/backend", container: nil, expectedKind: Kind.backend.rawValue),
    .init(name: "bun", port: 3002, uid: 501, exe: "/usr/local/bin/bun", command: "bun run dev", cwd: "/tmp/backend", container: nil, expectedKind: Kind.backend.rawValue),
    .init(name: "cargo", port: 8082, uid: 501, exe: "/usr/local/bin/cargo", command: "cargo run", cwd: "/tmp/backend", container: nil, expectedKind: Kind.backend.rawValue),
    .init(name: "deno", port: 8002, uid: 501, exe: "/usr/local/bin/deno", command: "deno run --allow-net main.ts", cwd: "/tmp/backend", container: nil, expectedKind: Kind.backend.rawValue),

    // Databases
    .init(name: "postgres", port: 5432, uid: 501, exe: "/opt/homebrew/bin/postgres", command: "postgres -D /tmp/data", cwd: "/tmp/database", container: nil, expectedKind: Kind.database.rawValue),
    .init(name: "mysqld", port: 3306, uid: 501, exe: "/usr/local/bin/mysqld", command: "mysqld", cwd: "/tmp/database", container: nil, expectedKind: Kind.database.rawValue),
    .init(name: "redis-server", port: 6379, uid: 501, exe: "/usr/local/bin/redis-server", command: "redis-server", cwd: "/tmp/database", container: nil, expectedKind: Kind.database.rawValue),
    .init(name: "mongod", port: 27017, uid: 501, exe: "/usr/local/bin/mongod", command: "mongod --dbpath /tmp/data", cwd: "/tmp/database", container: nil, expectedKind: Kind.database.rawValue),
    .init(name: "valkey-server", port: 6380, uid: 501, exe: "/usr/local/bin/valkey-server", command: "valkey-server", cwd: "/tmp/database", container: nil, expectedKind: Kind.database.rawValue),
    .init(name: "kafka", port: 9092, uid: 501, exe: "/usr/local/bin/kafka", command: "kafka-server-start", cwd: "/tmp/database", container: nil, expectedKind: Kind.database.rawValue),

    // Docker
    .init(name: "Docker Desktop backend", port: 2375, uid: 501, exe: "/Applications/Docker.app/Contents/Resources/bin/com.docker.backend", command: "com.docker.backend", cwd: "/tmp", container: nil, expectedKind: Kind.docker.rawValue),
    .init(name: "container-mapped port", port: 5432, uid: 501, exe: "/usr/bin/com.docker.backend", command: "com.docker.backend", cwd: "/tmp", container: "database", expectedKind: Kind.docker.rawValue),

    // Apps and System (Phase 3 split "System & Apps": app bundles and editor helpers are Apps; OS daemons stay System)
    .init(name: "VS Code extension", port: 9001, uid: 501, exe: "/Users/test/.vscode/extensions/oracle.sql-developer-1.0.0/server/node", command: "node extension.js", cwd: "/tmp", container: nil, expectedKind: Kind.app.rawValue),
    .init(name: "application helper", port: 9002, uid: 501, exe: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", command: "Code Helper", cwd: "/tmp", container: nil, expectedKind: Kind.app.rawValue),
    .init(name: "usr/libexec daemon", port: 9003, uid: 0, exe: "/usr/libexec/rapportd", command: "rapportd", cwd: "/", container: nil, expectedKind: Kind.system.rawValue),
    .init(name: "ControlCenter on 5000", port: 5000, uid: 0, exe: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", command: "ControlCenter", cwd: "/", container: nil, expectedKind: Kind.system.rawValue),
    .init(name: "Electron app", port: 9004, uid: 501, exe: "/Applications/Electron.app/Contents/MacOS/Electron", command: "Electron", cwd: "/tmp", container: nil, expectedKind: Kind.app.rawValue),
    .init(name: "Gemini extension", port: 9005, uid: 501, exe: "/Users/test/.gemini/helper", command: "helper", cwd: "/tmp", container: nil, expectedKind: Kind.app.rawValue)
]

private func listener(from fixture: ClassifierFixture) -> Listener {
    Listener(
        port: fixture.port,
        pid: 1234,
        start: 1,
        uid: fixture.uid,
        exposed: false,
        exe: fixture.exe,
        command: fixture.command,
        cwd: fixture.cwd,
        container: fixture.container
    )
}

@Suite("Ports Core")
struct PortsCoreTests {
    @Test("Recorded ports list fixture contains current output shape")
    func recordedPortsListFixtureContainsCurrentOutputShape() throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "ports-list",
                withExtension: "txt",
                subdirectory: "Fixtures"
            )
        )
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
        let rows = fixture.split(separator: "\n").map(String.init)

        #expect(rows.count == 9)
        #expect(rows.allSatisfy { $0.first == ":" })
        #expect(rows.contains { $0.contains("Backend") && $0.contains("python3") })
        #expect(rows.contains { $0.contains("LAN") && $0.contains("ControlCenter") })
    }

    @Test("Scanner returns sorted valid listeners")
    func scannerReturnsSortedValidListeners() {
        let listeners = scan(docker: [:])

        #expect(
            listeners == listeners.sorted {
                ($0.kind.rawValue, $0.port, $0.pid) < ($1.kind.rawValue, $1.port, $1.pid)
            }
        )
        #expect(listeners.allSatisfy { (1...65535).contains($0.port) && $0.pid > 0 })
    }

    @Test("Classifier recognizes every current category fixture", arguments: classifierFixtures)
    func classifierRecognizesEveryCurrentCategoryFixture(_ fixture: ClassifierFixture) {
        #expect(classify(listener(from: fixture)).0.rawValue == fixture.expectedKind, "\(fixture.name)")
    }

    // Phase 1 #2: a folder name in a path no longer decides the tool.
    @Test("Classifier ignores directory names in paths")
    func classifierIgnoresFolderNames() {
        let fixture = Listener(
            port: 4321,
            pid: 1234,
            start: 1,
            uid: 501,
            exposed: false,
            exe: "/usr/bin/python3",
            command: "python3 /Users/test/work/astro-dashboard/app.py",
            cwd: "/Users/test/work/astro-dashboard",
            label: ""
        )

        #expect(classify(fixture).0 == .backend)
        #expect(classify(fixture).1 == "python3")
    }

    // Phase 1 #1: a specific non-loopback bind is reachable from the network.
    @Test("Specific LAN bind is network-reachable")
    func specificBindIsExposed() {
        let fixture = Listener(
            port: 8080,
            pid: 1234,
            start: 1,
            uid: 501,
            exposed: false,
            exposure: Exposure(ipv4: in_addr(s_addr: inet_addr("192.168.1.20"))),
            exe: "/usr/bin/python3",
            command: "python3 server.py",
            cwd: "/tmp/server",
            label: ""
        )

        #expect(fixture.exposure == .specific("192.168.1.20"))
        #expect(fixture.exposed == true)
    }

    @Test("Current Docker output parser handles fixture rows", arguments: [
        "web\t0.0.0.0:8080->80/tcp, :::8081->81/tcp, 127.0.0.1:9000-9002->90-92/tcp",
        "database\t[::1]:5432->5432/tcp, 127.0.0.1:6379->6379/tcp"
    ])
    func dockerOutputParserHandlesFixtureRows(_ line: String) {
        let result = parseCurrentDockerOutput("\(line)\n")

        if line.hasPrefix("web") {
            #expect(result[8080] == "web")
            #expect(result[8081] == "web")
            #expect(result[9000] == "web")
            #expect(result[9001] == "web")
            #expect(result[9002] == "web")
        } else {
            #expect(result[5432] == "database")
            #expect(result[6379] == "database")
        }
    }

    @Test("Current Docker output parser ignores invalid names")
    func dockerOutputParserIgnoresInvalidNames() {
        let output = "../invalid\t0.0.0.0:8080->80/tcp\nvalid_name\t0.0.0.0:8081->80/tcp\n"
        let result = parseCurrentDockerOutput(output)

        #expect(result[8080] == nil)
        #expect(result[8081] == "valid_name")
    }

    @Test("Current Docker output parser caps port ranges at 1000 ports")
    func dockerOutputParserCapsPortRanges() {
        let result = parseCurrentDockerOutput("wide\t0.0.0.0:1000-9999->80-9079/tcp\n")

        #expect(result[1000] == "wide")
        #expect(result[2000] == "wide")
        #expect(result[2001] == nil)
    }

    @Test("Exposure detection matches current loopback and wildcard behavior", arguments: [
        ExposureFixture(name: "IPv4 loopback", address: .ipv4Loopback, expected: false),
        ExposureFixture(name: "IPv6 loopback", address: .ipv6Loopback, expected: false),
        ExposureFixture(name: "IPv4 wildcard", address: .ipv4Wildcard, expected: true),
        ExposureFixture(name: "IPv6 wildcard", address: .ipv6Wildcard, expected: true)
    ])
    func exposureDetectionMatchesCurrentBehavior(_ fixture: ExposureFixture) throws {
        let socket = try ListeningSocket(address: fixture.address)
        defer { socket.close() }

        let ports = Proc.listeningPorts(getpid())
        let match = try #require(ports.first { $0.port == socket.port })
        #expect(match.exposed == fixture.expected, "\(fixture.name)")
    }

    @Test("Kill ladder protects Ports process")
    func killLadderProtectsPortsProcess() {
        #expect(safeTerminate(pid: getpid(), start: 0) == .protected)
        #expect(safeTerminate(pid: 1, start: 0) == .protected)
    }

    @Test("Kill ladder rejects stale process identity")
    func killLadderRejectsStaleProcessIdentity() {
        #expect(safeTerminate(pid: getpid() + 100_000, start: 0) == .gone)
    }

    @Test("Kill ladder gracefully stops owned child")
    func killLadderGracefullyStopsOwnedChild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }

        let identity = try #require(Proc.identity(child.processIdentifier))

        #expect(safeTerminate(pid: child.processIdentifier, start: identity.start) == nil)
        child.waitUntilExit()
        #expect(!child.isRunning)
    }
}

struct ExposureFixture: Sendable {
    let name: String
    let address: SocketAddress
    let expected: Bool
}

enum SocketAddress: Sendable {
    case ipv4Loopback
    case ipv6Loopback
    case ipv4Wildcard
    case ipv6Wildcard
}

private struct ListeningSocket {
    let descriptor: Int32
    let port: Int

    init(address: SocketAddress) throws {
        let socketDescriptor = socket(
            address.isIPv6 ? AF_INET6 : AF_INET,
            SOCK_STREAM,
            0
        )
        guard socketDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let bindResult: Int32
        if address.isIPv6 {
            var value = sockaddr_in6()
            value.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            value.sin6_family = sa_family_t(AF_INET6)
            value.sin6_port = 0
            value.sin6_addr = address.ipv6Address
            bindResult = withUnsafePointer(to: &value) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var value = sockaddr_in()
            value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            value.sin_family = sa_family_t(AF_INET)
            value.sin_port = 0
            value.sin_addr = address.ipv4Address
            bindResult = withUnsafePointer(to: &value) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard bindResult == 0, listen(socketDescriptor, 1) == 0 else {
            Darwin.close(socketDescriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let actualPort: Int
        if address.isIPv6 {
            var value = sockaddr_in6()
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getsockname(
                socketDescriptor,
                withUnsafeMutablePointer(to: &value) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                },
                &length
            ) == 0 else {
                Darwin.close(socketDescriptor)
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            actualPort = Int(UInt16(bigEndian: value.sin6_port))
        } else {
            var value = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            guard getsockname(
                socketDescriptor,
                withUnsafeMutablePointer(to: &value) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                },
                &length
            ) == 0 else {
                Darwin.close(socketDescriptor)
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            actualPort = Int(UInt16(bigEndian: value.sin_port))
        }

        self.descriptor = socketDescriptor
        self.port = actualPort
    }

    func close() {
        Darwin.close(descriptor)
    }
}

private extension SocketAddress {
    var isIPv6: Bool {
        switch self {
        case .ipv6Loopback, .ipv6Wildcard: true
        case .ipv4Loopback, .ipv4Wildcard: false
        }
    }

    var ipv4Address: in_addr {
        switch self {
        case .ipv4Loopback:
            in_addr(s_addr: inet_addr("127.0.0.1"))
        case .ipv4Wildcard:
            in_addr(s_addr: inet_addr("0.0.0.0"))
        case .ipv6Loopback, .ipv6Wildcard:
            in_addr(s_addr: 0)
        }
    }

    var ipv6Address: in6_addr {
        switch self {
        case .ipv6Loopback:
            in6addr_loopback
        case .ipv6Wildcard:
            in6addr_any
        case .ipv4Loopback, .ipv4Wildcard:
            in6addr_any
        }
    }
}

private func parseCurrentDockerOutput(_ output: String) -> [Int: String] {
    let regex = try! NSRegularExpression(pattern: #":(\d+)(?:-(\d+))?->"#)
    var map: [Int: String] = [:]

    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0].range(
                of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#,
                options: .regularExpression
              ) != nil else {
            continue
        }

        let ports = parts[1] as NSString
        for match in regex.matches(in: parts[1], range: NSRange(location: 0, length: ports.length)) {
            guard let lower = Int(ports.substring(with: match.range(at: 1))) else { continue }
            let upper = match.range(at: 2).location == NSNotFound
                ? lower
                : (Int(ports.substring(with: match.range(at: 2))) ?? lower)
            for port in lower...min(max(lower, upper), lower + 1000) {
                map[port] = parts[0]
            }
        }
    }

    return map
}
