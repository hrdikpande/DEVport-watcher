// Ports — a native macOS menu bar app that lists every listening TCP port with its PID,
// groups them (Frontend / Backend / Databases / Docker / System & Apps) and lets you stop them.
//
// Performance: ports, PIDs, paths and folders come straight from the kernel via libproc
// (no lsof/ps child processes). Scans run on a background queue; the menu opens instantly
// from a cache and updates in place.
//
// Security: classification uses the real executable path (argv can be faked); every kill
// re-checks the process start time (guards against PID reuse) and the owner; only your own
// processes can be signalled; the only child process ever started is the docker CLI, from a
// fixed absolute path, with a minimal environment, a timeout and validated arguments.

import Darwin
import Foundation

// MARK: - Model

public enum Kind: Int, CaseIterable, Sendable, Codable {
    case frontend, backend, database, docker, tunnel, ai, service, app, system
    public var title: String {
        ["Frontend", "Backend", "Databases", "Containers", "Tunnels & forwards", "AI & agents",
         "Background services", "Apps", "System"][rawValue]
    }
    public var symbol: String {
        ["macwindow", "server.rack", "cylinder.split.1x2", "shippingbox", "arrow.left.arrow.right.circle", "brain",
         "gearshape.2", "square.grid.2x2", "gearshape"][rawValue]
    }
    /// At most 14 characters, for the `ports list` column.
    public var shortTitle: String {
        ["Frontend", "Backend", "Databases", "Containers", "Tunnels", "AI & agents", "Services", "Apps", "System"][rawValue]
    }
    /// Stable name for settings files (rawValues may be reordered).
    public var id: String { ["frontend", "backend", "database", "container", "tunnel", "ai", "service", "app", "system"][rawValue] }
    public init?(id: String) { guard let k = Kind.allCases.first(where: { $0.id == id }) else { return nil }; self = k }
    public init(from decoder: Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        guard let k = Kind(id: id) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown kind \(id)"))
        }
        self = k
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(id) }
    /// Developer view: things you run while developing (not apps, background services or the OS).
    public var isDeveloper: Bool { rawValue <= Kind.ai.rawValue }
}
public enum Filter: Int, Sendable { case developer, system, all }

/// Where a listening socket is bound. Anything but loopback can be reached from other machines.
public enum Exposure: Equatable, Sendable {
    case loopback
    case allInterfaces
    case specific(String)           // one interface address, e.g. "192.168.1.20" or "fe80::1"

    public var isNetworkReachable: Bool { self != .loopback }

    /// Human-readable bind address for the UI.
    public var address: String {
        switch self {
        case .loopback: "127.0.0.1 / ::1"
        case .allInterfaces: "0.0.0.0 / ::"
        case .specific(let ip): ip
        }
    }

    public init(ipv4 addr: in_addr) {
        let host = UInt32(bigEndian: addr.s_addr)
        if host == 0 { self = .allInterfaces }
        else if host >> 24 == 127 { self = .loopback }
        else { self = .specific(ntop(AF_INET, addr)) }
    }

    public init(ipv6 addr: in6_addr) {
        let b = withUnsafeBytes(of: addr) { Array($0) }
        if b.allSatisfy({ $0 == 0 }) { self = .allInterfaces; return }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { self = .loopback; return }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {   // ::ffff:a.b.c.d
            var v4 = in_addr()
            withUnsafeMutableBytes(of: &v4) { $0.copyBytes(from: b[12..<16]) }
            self.init(ipv4: v4); return
        }
        self = .specific(ntop(AF_INET6, addr))
    }

    /// One process can bind a port on several addresses; report the widest.
    public func widest(_ other: Exposure) -> Exposure {
        func rank(_ e: Exposure) -> Int { switch e { case .loopback: 0; case .specific: 1; case .allInterfaces: 2 } }
        return rank(other) > rank(self) ? other : self
    }
}

func ntop<T>(_ family: Int32, _ addr: T) -> String {
    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let ok = withUnsafeBytes(of: addr) { inet_ntop(family, $0.baseAddress, &buf, socklen_t(buf.count)) != nil }
    return ok ? String(cString: buf) : "?"
}

public struct Listener: Equatable, Sendable {
    public let port: Int
    public let pid: pid_t
    public let start: UInt64        // process start time (µs) — identity check against PID reuse
    public let uid: uid_t
    public var exposure: Exposure
    public var addresses: [String]  // this process's own bind addresses on this port, e.g. ["127.0.0.1"], ["::1"]
    public var exposed: Bool { exposure.isNetworkReachable }   // reachable from your network
    public let exe: String          // real executable path from the kernel
    public let command: String      // argv joined (display only)
    public let argv: [String]       // tool detection only (argv can be faked; never used for safety)
    public let cwd: String
    public var container: String? = nil
    public var web: WebScheme? = nil     // set by probeWeb (menu open only); nil = not HTTP-like
    public var stopped = false      // suspended (SIGSTOP / Ctrl-Z): holds the port but serves nothing
    public var kind: Kind = .system
    public var label = ""
    // Phase 2 process model
    public var ppid: pid_t = 0
    public var pgid: pid_t = 0
    public var tty: Int32? = nil           // controlling terminal device; nil = none
    public var chain: [Ancestor] = []      // parent → … → launchd
    public var memory: UInt64 = 0          // resident bytes (own processes only)
    public var cpuNanos: UInt64 = 0        // total CPU time
    public var cpuPercent: Double? = nil   // sampled only while the panel is open
    public var connections = 0             // established TCP connections on this port
    public var workers: [pid_t] = []       // worker processes folded into this row
    public var project: Project? = nil
    // Phase 3 classification
    public var framework: String? = nil    // display name from the framework table
    public var confidence = 0              // 0–100
    public var tier: SafetyTier = .warning
    public var detectedKind: Kind? = nil   // set when an override moved the row to another category
    public var override: Override? = nil
    /// The category Ports detected. Safety decisions (stop policy, probing) always use this, never an override.
    public var baseKind: Kind { detectedKind ?? kind }
    public var isIdle: Bool { connections == 0 }
    public var startCommand: String { PortsCore.startCommand(cwd: cwd, argv: argv) }

    public init(port: Int, pid: pid_t, start: UInt64, uid: uid_t, exposed: Bool,
                exposure: Exposure? = nil, exe: String, command: String, argv: [String]? = nil, cwd: String, container: String? = nil,
                kind: Kind = .system, label: String = "") {
        self.port = port
        self.pid = pid
        self.start = start
        self.uid = uid
        self.exposure = exposure ?? (exposed ? .allInterfaces : .loopback)
        switch self.exposure {
        case .loopback: addresses = ["127.0.0.1"]
        case .allInterfaces: addresses = ["0.0.0.0"]
        case .specific(let ip): addresses = [ip]
        }
        self.exe = exe
        self.command = command
        self.argv = argv ?? command.split(separator: " ").map(String.init)
        self.cwd = cwd
        self.container = container
        self.kind = kind
        self.label = label
    }
}

public let home = FileManager.default.homeDirectoryForCurrentUser.path
public func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
func basename(_ p: String) -> String { (p as NSString).lastPathComponent }

// MARK: - Native process info (libproc / sysctl)

public enum Proc {
    public static func allPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 128)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return got > 0 ? Array(pids.prefix(Int(got))).filter { $0 > 0 } : []
    }

    public struct Identity: Equatable {
        public let uid: uid_t
        public let start: UInt64
    }
    public static func identity(_ pid: pid_t) -> Identity? {
        var bi = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, size) == size else { return nil }
        return Identity(uid: bi.pbi_uid, start: bi.pbi_start_tvsec &* 1_000_000 &+ bi.pbi_start_tvusec)
    }

    /// True when the process is suspended (kinfo_proc p_stat == SSTOP).
    public static func isStopped(_ pid: pid_t) -> Bool { state(pid).stopped }

    public static func exePath(_ pid: pid_t) -> String {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(decoding: buf.prefix(Int(n)), as: UTF8.self) : ""
    }

    public static func cwd(_ pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// argv via KERN_PROCARGS2: [argc:int32][exec path\0][padding \0…][argv0\0][argv1\0]…
    public static func commandLine(_ pid: pid_t) -> String { arguments(pid).joined(separator: " ") }

    public static func arguments(_ pid: pid_t) -> [String] { procArgs(pid).args }

    public struct BoundPort: Equatable {
        public let port: Int
        public let exposure: Exposure
        public let address: String          // the exact bound address, e.g. "127.0.0.1", "::1", "0.0.0.0"
        public var exposed: Bool { exposure.isNetworkReachable }
    }

    /// Listening TCP sockets of one process, with the address each is bound to.
    public static func listeningPorts(_ pid: pid_t) -> [BoundPort] { sockets(pid).listening }
}

// MARK: - Docker (the only external command; fixed path, minimal env, timeout)

/// Docker-compatible CLIs, first one found wins (Docker Desktop, Homebrew, OrbStack, Rancher Desktop, Podman).
public let containerCLIPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                                "/Applications/Docker.app/Contents/Resources/bin/docker",
                                home + "/.orbstack/bin/docker", home + "/.rd/bin/docker",
                                "/opt/homebrew/bin/podman"]
public let dockerPath = containerCLIPaths.first { FileManager.default.isExecutableFile(atPath: $0) }

/// The container runtime whose host-side proxy this executable is, if any. Only these processes
/// publish container ports, so only they may carry a container label.
public func containerRuntime(exe: String) -> String? {
    let name = basename(exe).lowercased()
    if exe.contains("/Docker.app/") || name.hasPrefix("com.docker") || ["vpnkit-bridge", "docker-proxy"].contains(name) {
        return "Docker"
    }
    if exe.contains("/OrbStack.app/") || name.hasPrefix("orbstack") { return "OrbStack" }
    if exe.contains("/Rancher Desktop.app/") || exe.contains("/.rd/") { return "Rancher Desktop" }
    if name == "limactl" || exe.contains("/colima/") || exe.contains("/.lima/") { return "Colima/Lima" }
    if name == "gvproxy" || name.hasPrefix("podman") { return "Podman" }
    return nil
}

/// Container name for a listener: only a container-runtime proxy can own a published port.
public func containerName(exe: String, port: Int, docker: [Int: String]) -> String? {
    containerRuntime(exe: exe) == nil ? nil : docker[port]
}

/// Query the container CLI only when a runtime's proxy is actually listening.
public func needsContainerQuery(_ listeners: [Listener]) -> Bool {
    dockerPath != nil && listeners.contains { containerRuntime(exe: $0.exe) != nil }
}

public func isSafeContainerName(_ s: String) -> Bool {
    s.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil
}

/// host port -> container name
public func dockerPorts() -> [Int: String] {
    guard let docker = dockerPath else { return [:] }
    let res = run(docker, ["ps", "--format", "{{.Names}}\t{{.Ports}}"])
    return res.ok ? parseDockerPorts(res.out) : [:]
}

func parseDockerPorts(_ out: String) -> [Int: String] {
    var map: [Int: String] = [:]
    let regex = try! NSRegularExpression(pattern: #":(\d+)(?:-(\d+))?->"#)
    for line in out.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2, isSafeContainerName(parts[0]) else { continue }
        let ports = parts[1] as NSString
        for m in regex.matches(in: parts[1], range: NSRange(location: 0, length: ports.length)) {
            guard let lo = Int(ports.substring(with: m.range(at: 1))) else { continue }
            let hi = m.range(at: 2).location == NSNotFound ? lo : (Int(ports.substring(with: m.range(at: 2))) ?? lo)
            for p in lo...min(max(lo, hi), lo + 1000) { map[p] = parts[0] }
        }
    }
    return map
}

// MARK: - Classification (edit these lists to teach it about your tools)

let interpreters: Set = ["node", "ruby", "bun", "deno", "php", "perl", "java"]     // + python*
let npxLike: Set = ["npx", "bunx", "pnpx"]                                         // <runner> <tool>
let runnerSubcommands = ["npm": ["exec"], "pnpm": ["exec", "dlx"], "yarn": ["exec", "dlx"], "bun": ["x"],
                         "uv": ["run"], "poetry": ["run"], "pipenv": ["run"]]       // <runner> <sub> <tool>
let noScriptFlags: Set = ["-c", "-e", "--eval", "-p", "--print"]                   // inline code follows
let valueFlags: Set = ["-r", "--require", "--import", "--loader", "--experimental-loader", "-W", "-X",
                       "-cp", "-classpath", "--class-path", "-p", "--module-path",
                       "--add-opens", "--add-exports", "--add-modules", "--add-reads"]   // java
let erlangVMs: Set = ["beam.smp", "beam", "erl", "erlexec"]

func isInterpreter(_ name: String) -> Bool { interpreters.contains(name) || name.hasPrefix("python") }

/// First operand that is not a flag (or a flag's value); nil if inline code is run instead.
func firstOperand(_ args: ArraySlice<String>) -> String? {
    var i = args.startIndex
    while i < args.endIndex {
        let a = args[i]
        if noScriptFlags.contains(a) { return nil }
        if valueFlags.contains(a) { i += 2; continue }
        if !a.hasPrefix("-") { return a }
        i += 1
    }
    return nil
}

/// "vite@5" -> "vite", "@scope/pkg@1" -> "pkg"
func packageName(_ s: String) -> String {
    var n = s.hasPrefix("@") ? String(s.split(separator: "/").dropFirst().first ?? "") : s
    if let at = n.firstIndex(of: "@") { n = String(n[..<at]) }
    return n
}

/// A script path names the tool only through node_modules (or its own file name) — never its folders.
func scriptName(_ path: String) -> String {
    if let r = path.range(of: "node_modules/.bin/", options: .backwards) {
        return String(path[r.upperBound...].split(separator: "/").first ?? "")
    }
    if let r = path.range(of: "node_modules/", options: .backwards) {
        let parts = path[r.upperBound...].split(separator: "/").map(String.init)
        if let first = parts.first { return first.hasPrefix("@") && parts.count > 1 ? parts[1] : first }
    }
    return basename(path)
}

/// What the process *is*: exe basename, argv[0], and the tool/script/module it runs.
/// Directory names in paths are deliberately ignored ("~/work/astro-dashboard/app.py" is not Astro).
func identityNames(exe: String, argv: [String]) -> [String] {
    let exeName = basename(exe).lowercased()
    var names = [exeName]
    guard let first = argv.first else { return names }
    let a0 = basename(first.split(separator: " ").first.map(String.init) ?? first).lowercased()
    names.append(a0)
    let rest = argv.dropFirst()

    if npxLike.contains(a0) {
        if let t = firstOperand(rest) { names.append(packageName(t)) }
    } else if let subs = runnerSubcommands[a0], let sub = rest.first, subs.contains(sub) {
        if let t = firstOperand(rest.dropFirst()) { names.append(packageName(t)) }
    } else if erlangVMs.contains(a0) || erlangVMs.contains(exeName) {
        // The Erlang VM runs RabbitMQ and CouchDB: the app is named by `-s/-run <app>`,
        // `-progname <name>` or the `-boot <release>` file, never by the install folder.
        for (flag, value) in zip(rest, rest.dropFirst()) where ["-s", "-run", "-progname", "-boot"].contains(flag) {
            names.append(basename(value))
        }
        if names.contains(where: { $0.lowercased().hasPrefix("rabbit") }) || rest.contains(where: { $0.hasPrefix("-rabbit") }) {
            names.append("rabbitmq")
        }
    } else if isInterpreter(a0) || isInterpreter(exeName) {
        let runner = isInterpreter(a0) ? a0 : exeName
        if runner.hasPrefix("python"), let m = rest.firstIndex(of: "-m"), m + 1 < rest.endIndex {
            names.append(rest[m + 1])                                   // python -m uvicorn
        } else if runner == "java" {
            if let j = rest.firstIndex(of: "-jar"), j + 1 < rest.endIndex { names.append(basename(rest[j + 1])) }
            else if let main = firstOperand(rest) {
                names += main.split(separator: ".").map(String.init)      // org.neo4j.server.… -> neo4j
            }
        } else {
            let args = (["bun", "deno"].contains(runner) && rest.first == "run") ? rest.dropFirst() : rest
            if let script = firstOperand(args) { names.append(scriptName(script)) }
        }
    }
    return names.map { $0.lowercased() }.filter { !$0.isEmpty }
}
// MARK: - Web probe (menu open only; loopback addresses only; < 1 s per listener; read-only)

public enum WebScheme: String, Sendable { case http, https }

/// Decide from a server's first bytes whether it speaks HTTP, HTTPS, or neither.
public func webScheme(fromReply b: [UInt8]) -> WebScheme? {
    if b.starts(with: Array("HTTP/".utf8)) {
        let text = String(decoding: b, as: UTF8.self).lowercased()   // nginx: "plain HTTP request was sent to HTTPS port"
        return text.contains("https port") || text.contains("speak https") ? .https : .http
    }
    if b.count >= 2, b[0] == 0x15 || b[0] == 0x16, b[1] == 0x03 { return .https }   // TLS alert / handshake record
    return nil
}

let httpProbe = Array("HEAD / HTTP/1.0\r\nHost: localhost\r\nUser-Agent: Ports\r\n\r\n".utf8)
/// Minimal TLS 1.2 ClientHello. Any TLS server answers with a handshake (0x16) or an alert (0x15).
let tlsProbe: [UInt8] = [0x16, 0x03, 0x01, 0x00, 0x33,                  // record: handshake, 51 bytes
                         0x01, 0x00, 0x00, 0x2f, 0x03, 0x03]            // ClientHello, 47 bytes, TLS 1.2
    + [UInt8](repeating: 0x2a, count: 32)                               // random
    + [0x00, 0x00, 0x06, 0xc0, 0x2f, 0x00, 0x9c, 0x00, 0x2f,            // no session; 3 cipher suites
       0x01, 0x00, 0x00, 0x00]                                          // null compression; no extensions

/// Send `payload`, return the first bytes of the reply ([] if none), or nil if we couldn't connect.
func exchange(host: String, port: Int, payload: [UInt8], deadline: Date) -> [UInt8]? {
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return nil }
    defer { freeaddrinfo(res) }
    let fd = socket(ai.pointee.ai_family, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    func ms() -> Int32 { Int32(max(0, deadline.timeIntervalSinceNow) * 1000) }
    if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) != 0 {
        guard errno == EINPROGRESS else { return nil }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var err: Int32 = 0, len = socklen_t(MemoryLayout<Int32>.size)
        guard poll(&p, 1, ms()) == 1, getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { return nil }
    }
    guard payload.withUnsafeBytes({ send(fd, $0.baseAddress, payload.count, 0) }) == payload.count else { return [] }
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&p, 1, ms()) == 1 else { return [] }
    var buf = [UInt8](repeating: 0, count: 512)
    let n = recv(fd, &buf, buf.count, 0)
    return n > 0 ? Array(buf.prefix(n)) : []
}

/// Worth probing: dev servers and published container ports that answer on loopback.
/// Never Databases-kind, system or suspended processes, and never a non-loopback address.
public func isWebCandidate(_ l: Listener) -> Bool {
    if case .specific = l.exposure { return false }       // bound to a LAN address only: not reachable on loopback
    return !l.stopped && l.baseKind != .database && (l.container != nil || l.baseKind == .frontend || l.baseKind == .backend)
}

public let webProbeBudget: TimeInterval = 0.8             // whole probe of one listener, all attempts included

/// Plain HTTP first; if the server says nothing, try a TLS hello. Loopback only, within `webProbeBudget`.
public func probeWeb(_ l: Listener) -> WebScheme? {
    guard isWebCandidate(l) else { return nil }
    let deadline = Date().addingTimeInterval(webProbeBudget)
    for host in ["127.0.0.1", "::1"] {
        guard let reply = exchange(host: host, port: l.port, payload: httpProbe, deadline: deadline) else { continue }
        if let scheme = webScheme(fromReply: reply) { return scheme }
        guard reply.isEmpty else { return nil }                 // spoke, but not HTTP or TLS
        let tls = exchange(host: host, port: l.port, payload: tlsProbe, deadline: deadline) ?? []
        return webScheme(fromReply: tls) == .https ? .https : nil
    }
    return nil
}

public func browserURL(_ l: Listener, _ scheme: WebScheme) -> URL? {
    var host = "localhost"
    if case .specific(let ip) = l.exposure { host = ip.contains(":") ? "[\(ip)]" : ip }
    return URL(string: "\(scheme.rawValue)://\(host):\(l.port)")
}

// MARK: - System processes on dev ports

public enum KnownPorts {
    /// Ports dev servers usually want. A system process here is the likely cause of "address in use".
    public static let commonDevPorts: Set<Int> = [3000, 3001, 3306, 4000, 4200, 4321, 5000, 5001, 5173, 5432,
                                                  6006, 6379, 7000, 8000, 8001, 8080, 8081, 8443, 8888, 9000,
                                                  9229, 27017]

    /// System processes launchd starts again at once: killing them never frees the port.
    public static let restartedByLaunchd: Set<String> = ["ControlCenter", "rapportd", "sharingd", "remoted",
                                                         "AirPlayXPCHelper", "mDNSResponder", "identityservicesd"]

    public static func restartsAutomatically(_ l: Listener) -> Bool {
        l.baseKind == .system && restartedByLaunchd.contains(appName(l.exe))
    }

    public static var currentOSMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    /// The General pane holding AirPlay Receiver: "AirDrop & Handoff" through macOS 15 (Apple's macOS 13 guide);
    /// renamed "AirDrop & Continuity" in macOS 26 Tahoe (the only version confirmed renamed).
    public static func airPlayPane(osMajor: Int = currentOSMajor) -> String {
        osMajor >= 26 ? "AirDrop & Continuity" : "AirDrop & Handoff"
    }

    public static let airPlaySettingsURL = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")!

    static func isAirPlayReceiver(_ l: Listener) -> Bool {
        l.baseKind == .system && appName(l.exe) == "ControlCenter" && (l.port == 5000 || l.port == 7000)
    }

    /// The settings action that actually frees the port, if there is one.
    public static func settingsAction(_ l: Listener) -> (title: String, url: URL)? {
        isAirPlayReceiver(l) ? ("Open AirPlay Settings", airPlaySettingsURL) : nil
    }

    /// Why a system process holds a common dev port, and how to free it.
    public static func explanation(_ l: Listener, osMajor: Int = currentOSMajor) -> String? {
        guard !l.baseKind.isDeveloper, commonDevPorts.contains(l.port) else { return nil }
        let app = appName(l.exe)
        if isAirPlayReceiver(l) {
            return "AirPlay Receiver (ControlCenter) uses port \(l.port). To free it, turn off System Settings › "
                + "General › \(airPlayPane(osMajor: osMajor)) › AirPlay Receiver."
        }
        return "\(app) is using port \(l.port), a common dev-server port, so a dev server can't bind it."
    }
}

/// Developer view: dev kinds, plus any system process sitting on a common dev port (never hidden).
public func showsInDeveloperView(_ l: Listener) -> Bool {
    l.kind.isDeveloper || KnownPorts.explanation(l) != nil
}

// MARK: - Scan (runs off the main thread)

/// One scan of every listening socket. Static per-process data comes from `cache` (keyed by pid + start
/// time); what can change (ppid, state, TTY, metrics, connections, branch) is read every time.
/// `sampleCPU` (panel open only) adds CPU % from the previous sample.
public func scan(docker: [Int: String], cache: ProcessCache = .shared, sampleCPU: Bool = false,
                 cpu: CPUSampler = .shared) -> [Listener] {
    var out: [Listener] = []
    var branches: [String: String?] = [:]          // repo root -> branch, read once per scan
    let now = DispatchTime.now().uptimeNanoseconds
    for pid in Proc.allPIDs() {
        let sockets = Proc.sockets(pid)
        guard !sockets.listening.isEmpty, let bsd = Proc.bsdInfo(pid) else { continue }
        let info = cache.info(pid: pid, start: bsd.start)
        let exe = info.exe, args = info.argv, cwd = info.cwd
        let cmd = args.joined(separator: " "), state = Proc.state(pid)
        let metrics = Proc.metrics(pid)
        let chain = Proc.launcherChain(parent: bsd.ppid, cache: cache)
        var project = info.project
        if let root = project?.repoRoot {
            if branches[root] == nil { branches[root] = .some(GitInfo.branch(repoRoot: root)) }
            project?.branch = branches[root] ?? nil
        }
        let cpuPct = sampleCPU ? metrics.flatMap {
            cpu.sample(key: ProcessCache.key(pid, bsd.start), cpuNanos: $0.cpuNanos, at: now)
        } : nil
        var byPort: [Int: Exposure] = [:], addrs: [Int: [String]] = [:]
        for p in sockets.listening {
            byPort[p.port] = byPort[p.port].map { $0.widest(p.exposure) } ?? p.exposure
            if !(addrs[p.port] ?? []).contains(p.address) { addrs[p.port, default: []].append(p.address) }
        }
        for (port, exposure) in byPort {
            var l = Listener(port: port, pid: pid, start: bsd.start, uid: bsd.uid, exposed: exposure.isNetworkReachable,
                             exposure: exposure, exe: exe, command: cmd.isEmpty ? exe : cmd,
                             argv: args.isEmpty ? [exe] : args, cwd: cwd,
                             container: containerName(exe: exe, port: port, docker: docker))
            l.stopped = state.stopped
            l.tty = state.tty
            l.ppid = bsd.ppid
            l.pgid = bsd.pgid
            l.chain = chain
            l.memory = metrics?.resident ?? 0
            l.cpuNanos = metrics?.cpuNanos ?? 0
            l.cpuPercent = cpuPct
            l.connections = sockets.established[port] ?? 0
            l.project = project
            l.addresses = addrs[port] ?? l.addresses
            let c = classifyDetailed(l)
            l.kind = c.kind
            l.framework = c.framework?.name
            l.confidence = c.confidence
            l.tier = c.tier
            l.label = rowLabel(kind: c.kind, tool: c.name, cwd: cwd, project: project)
            out.append(l)
        }
    }
    cache.endScan()
    if sampleCPU { cpu.forget(keeping: Set(out.map { ProcessCache.key($0.pid, $0.start) })) }
    return groupWorkers(out).sorted { ($0.kind.rawValue, $0.port, $0.pid) < ($1.kind.rawValue, $1.port, $1.pid) }
}

/// "vite · shop › web · main" for dev servers; the folder name when no project is found (home folders only);
/// just the tool for containers and system processes.
public func rowLabel(kind: Kind, tool: String, cwd: String, project: Project?) -> String {
    guard kind.isDeveloper && kind != .docker else { return tool }
    if let project { return "\(tool) · \(project.displayWithBranch)" }
    let folder = cwd.hasPrefix(home + "/") ? basename(cwd) : ""
    return folder.isEmpty ? tool : "\(tool) · \(folder)"
}

/// One `ports list` row; the LAN and STOPPED badges match the menu.
public func listRow(_ l: Listener) -> String {
    [":\(l.port)".padding(toLength: 7, withPad: " ", startingAt: 0),
     "\(l.pid)".padding(toLength: 7, withPad: " ", startingAt: 0),
     l.kind.shortTitle.padding(toLength: 14, withPad: " ", startingAt: 0),
     (l.exposed ? "LAN " : "    ") + l.label + (l.workers.isEmpty ? "" : "  ×\(l.workers.count + 1) workers")
        + (l.stopped ? "  STOPPED" : "")].joined(separator: " ")
}

/// One fresh scan with container labels queried in the same pass (never a stale port map).
public func scanWithContainers() -> [Listener] {
    let first = scan(docker: [:])
    return needsContainerQuery(first) ? scan(docker: dockerPorts()) : first
}

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
