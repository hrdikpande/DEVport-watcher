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

import AppKit
import Darwin

// MARK: - Model

public enum Kind: Int, CaseIterable {
    case frontend, backend, database, docker, system
    public var title: String { ["Frontend", "Backend", "Databases", "Docker", "System & Apps"][rawValue] }
    public var symbol: String { ["macwindow", "server.rack", "cylinder.split.1x2", "shippingbox", "gearshape"][rawValue] }
    public var isDeveloper: Bool { self != .system }
}
public enum Filter: Int { case developer, system, all }

public struct Listener: Equatable {
    public let port: Int
    public let pid: pid_t
    public let start: UInt64        // process start time (µs) — identity check against PID reuse
    public let uid: uid_t
    public var exposed: Bool        // listening on all interfaces (reachable from your network)
    public let exe: String          // real executable path from the kernel
    public let command: String      // argv joined (display + tool detection only)
    public let cwd: String
    public var container: String? = nil
    public var kind: Kind = .system
    public var label = ""

    public init(port: Int, pid: pid_t, start: UInt64, uid: uid_t, exposed: Bool,
                exe: String, command: String, cwd: String, container: String? = nil,
                kind: Kind = .system, label: String = "") {
        self.port = port
        self.pid = pid
        self.start = start
        self.uid = uid
        self.exposed = exposed
        self.exe = exe
        self.command = command
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
    public static func commandLine(_ pid: pid_t) -> String {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0 else { return "" }
        var buf = [UInt8](repeating: 0, count: Int(argmax))
        size = buf.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return "" }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }      // skip exec path
        while i < size && buf[i] == 0 { i += 1 }      // skip padding
        var args: [String] = [], start = i
        while i < size && args.count < argc {
            if buf[i] == 0 { args.append(String(decoding: buf[start..<i], as: UTF8.self)); start = i + 1 }
            i += 1
        }
        return args.joined(separator: " ")
    }

    /// Listening TCP sockets of one process: (port, exposedToNetwork).
    public static func listeningPorts(_ pid: pid_t) -> [(port: Int, exposed: Bool)] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }

        var result: [(Int, Bool)] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let siSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, siSize) == siSize,
                  si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            let exposed: Bool
            if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
                exposed = ini.insi_laddr.ina_46.i46a_addr4.s_addr == INADDR_ANY
            } else {
                var any = in6addr_any, addr = ini.insi_laddr.ina_6
                exposed = memcmp(&addr, &any, MemoryLayout<in6_addr>.size) == 0
            }
            result.append((port, exposed))
        }
        return result
    }
}

// MARK: - Docker (the only external command; fixed path, minimal env, timeout)

public let dockerPath = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                  "/Applications/Docker.app/Contents/Resources/bin/docker"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

public func run(_ path: String, _ args: [String], timeout: TimeInterval = 3) -> (out: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args                                            // argv array: no shell, no injection
    p.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("", false) }
    let done = DispatchSemaphore(value: 0)
    var data = Data()
    DispatchQueue.global(qos: .utility).async { data = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = done.wait(timeout: .now() + 1)
        return ("Timed out after \(Int(timeout)) s", false)
    }
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus == 0)
}

public func isSafeContainerName(_ s: String) -> Bool {
    s.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil
}

/// host port -> container name
public func dockerPorts() -> [Int: String] {
    guard let docker = dockerPath else { return [:] }
    let res = run(docker, ["ps", "--format", "{{.Names}}\t{{.Ports}}"])
    guard res.ok else { return [:] }
    var map: [Int: String] = [:]
    let regex = try! NSRegularExpression(pattern: #":(\d+)(?:-(\d+))?->"#)
    for line in res.out.split(separator: "\n") {
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

let dbNames = ["postgres", "mysqld", "mariadbd", "mongod", "redis-server", "memcached", "clickhouse",
               "influxd", "cockroach", "elasticsearch", "opensearch", "neo4j", "couchdb", "rabbitmq",
               "nats-server", "kafka", "surreal", "valkey-server"]
let frontendTools = ["vite", "next", "next-server", "astro", "nuxt", "webpack", "react-scripts", "parcel",
                     "svelte-kit", "remix", "gatsby", "ng", "live-server", "http-server", "eleventy",
                     "storybook", "expo", "metro", "serve"]
let backendTools = ["node", "python", "python3", "ruby", "php", "java", "go", "deno", "bun", "uvicorn",
                    "gunicorn", "flask", "manage.py", "rails", "puma", "dotnet", "cargo", "nodemon", "tsx",
                    "ts-node", "nest", "air", "hypercorn", "fastapi", "supabase"]
let appTools = ["claude", "agy", "electron"]                   // dev *apps*, not servers you started
let wellKnownPorts = [5432: "postgres", 3306: "mysql", 6379: "redis", 27017: "mongo", 9200: "elasticsearch",
                      5672: "rabbitmq", 11211: "memcached", 1433: "sql server"]

func tokens(_ s: String) -> [String] {
    s.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
}
func matches(_ toks: [String], _ tools: [String]) -> String? {
    for t in toks { for tool in tools where t == tool || t.hasPrefix(tool + ".") || t.hasPrefix(tool + "-") { return tool } }
    return nil
}

/// "Visual Studio Code", "VS Code ext: oracle.sql-developer", "rapportd"…
func appName(_ exe: String) -> String {
    if let r = exe.range(of: "/.vscode/extensions/") {
        let ext = exe[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        return "VS Code ext: " + ext.replacingOccurrences(of: #"-\d.*$"#, with: "", options: .regularExpression)
    }
    if let r = exe.range(of: ".app/") { return basename(String(exe[..<r.lowerBound])) }
    return basename(exe)
}

public func classify(_ l: Listener) -> (Kind, String) {
    let toks = tokens(l.command)
    let exeName = basename(l.exe).lowercased()
    let argv0 = basename(l.command.split(separator: " ").first.map(String.init) ?? "").lowercased()

    if let c = l.container { return (.docker, c) }
    if l.exe.contains("/Docker.app/") || exeName.hasPrefix("com.docker") {
        let guess = wellKnownPorts[l.port].map { "\($0)? · " } ?? ""
        return (.docker, "\(guess)Docker engine")
    }
    if let db = matches([exeName] + toks, dbNames) { return (.database, db) }
    // Dev apps & editor helpers (they embed node/java, but you didn't start them).
    if appTools.contains(argv0) || l.exe.contains("/.vscode/extensions/") || l.exe.contains("/.gemini/")
        || (l.exe.contains(".app/") && !backendTools.contains(exeName)) {
        return (.system, appTools.contains(argv0) ? argv0 : appName(l.exe))
    }
    let isOS = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains(where: l.exe.hasPrefix)
    if !isOS, let fe = matches(toks, frontendTools) { return (.frontend, fe) }
    if !isOS, let be = matches([exeName] + toks, backendTools) { return (.backend, be) }
    return (.system, appName(l.exe))
}

// MARK: - Scan (runs off the main thread)

public func scan(docker: [Int: String]) -> [Listener] {
    var out: [Listener] = []
    for pid in Proc.allPIDs() {
        let ports = Proc.listeningPorts(pid)
        guard !ports.isEmpty, let id = Proc.identity(pid) else { continue }
        let exe = Proc.exePath(pid), cmd = Proc.commandLine(pid), cwd = Proc.cwd(pid)
        var byPort: [Int: Bool] = [:]
        for p in ports { byPort[p.port] = (byPort[p.port] ?? false) || p.exposed }
        for (port, exposed) in byPort {
            var l = Listener(port: port, pid: pid, start: id.start, uid: id.uid, exposed: exposed,
                             exe: exe, command: cmd.isEmpty ? exe : cmd, cwd: cwd, container: docker[port])
            let (kind, tool) = classify(l)
            l.kind = kind
            let folder = (cwd.hasPrefix(home + "/")) ? basename(cwd) : ""
            l.label = (kind.isDeveloper && kind != .docker && !folder.isEmpty) ? "\(tool) · \(folder)" : tool
            out.append(l)
        }
    }
    return out.sorted { ($0.kind.rawValue, $0.port, $0.pid) < ($1.kind.rawValue, $1.port, $1.pid) }
}

// MARK: - Safe kill

public enum KillError: Error, Equatable, CustomStringConvertible {
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

/// SIGTERM, then SIGKILL after 2 s — re-verifying identity before each signal.
public func safeTerminate(pid: pid_t, start: UInt64) -> KillError? {
    guard pid > 1, pid != getpid() else { return .protected }
    guard let id = Proc.identity(pid), id.start == start else { return .gone }
    guard id.uid == getuid() else { return .notYours }
    if kill(pid, SIGTERM) != 0 { return .failed(String(cString: strerror(errno))) }
    for _ in 0..<20 {
        usleep(100_000)
        if Proc.identity(pid)?.start != start { return nil }       // exited
    }
    if Proc.identity(pid)?.start == start { kill(pid, SIGKILL) }
    return nil
}
