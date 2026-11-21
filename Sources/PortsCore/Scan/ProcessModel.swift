// Phase 2: richer process model — parent/tree, TTY, metrics, connections, workers, start command.
import Darwin
import Foundation

/// One step of a launcher chain: the parent, its parent, … up to launchd.
public struct Ancestor: Equatable, Sendable {
    public let pid: pid_t
    public let name: String         // kernel process name (Claude Code reports its version here)
    public let exe: String
    public let command: String      // basename of argv[0] when readable (own processes), else `name`
    public let uid: uid_t?
    public init(pid: pid_t, name: String, exe: String, command: String? = nil, uid: uid_t? = nil) {
        self.pid = pid; self.name = name; self.exe = exe; self.command = command ?? name; self.uid = uid
    }
}

/// Fields of `proc_bsdinfo` the model uses.
public struct BSDInfo: Equatable, Sendable {
    public let ppid: pid_t
    public let pgid: pid_t
    public let uid: uid_t
    public let start: UInt64        // µs since the epoch
    public let name: String         // pbi_name (falls back to pbi_comm)
}

extension Proc {
    public static func bsdInfo(_ pid: pid_t) -> BSDInfo? {
        var bi = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, size) == size else { return nil }
        func text<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        }
        let name = text(bi.pbi_name)
        return BSDInfo(ppid: pid_t(bi.pbi_ppid), pgid: pid_t(bi.pbi_pgid), uid: bi.pbi_uid,
                       start: bi.pbi_start_tvsec &* 1_000_000 &+ bi.pbi_start_tvusec,
                       name: name.isEmpty ? text(bi.pbi_comm) : name)
    }

    /// Parent, group, owner, start and name from `kinfo_proc`, which (unlike libproc) also answers for
    /// processes of other users, such as a root `login` in a launcher chain.
    public static func kinfoInfo(_ pid: pid_t) -> BSDInfo? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return BSDInfo(ppid: info.kp_eproc.e_ppid, pgid: info.kp_eproc.e_pgid, uid: info.kp_eproc.e_ucred.cr_uid,
                       start: UInt64(t.tv_sec) &* 1_000_000 &+ UInt64(t.tv_usec), name: name)
    }

    public struct Brief: Equatable, Sendable {
        public let pid: pid_t
        public let ppid: pid_t
        public let tty: Int32?
        public let name: String
    }

    /// Every process of `uid` in one sysctl (pid, parent, terminal, name): cheap enough for each scan.
    public static func all(uid: uid_t) -> [Brief] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).map { p in
            let name = withUnsafeBytes(of: p.kp_proc.p_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            return Brief(pid: p.kp_proc.p_pid, ppid: p.kp_eproc.e_ppid, tty: ttyDevice(p.kp_eproc.e_tdev), name: name)
        }
    }

    /// Suspended state and controlling terminal, from one `kinfo_proc` read.
    public static func state(_ pid: pid_t) -> (stopped: Bool, tty: Int32?) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return (false, nil) }
        return (Int32(info.kp_proc.p_stat) == SSTOP, ttyDevice(info.kp_eproc.e_tdev))
    }

    /// `e_tdev` is NODEV (-1) when the process has no controlling terminal.
    public static func ttyDevice(_ dev: dev_t) -> Int32? { dev == -1 ? nil : dev }

    /// Resident memory (bytes) and total CPU time (ns). Own processes only (the kernel refuses others).
    public static func metrics(_ pid: pid_t) -> (resident: UInt64, cpuNanos: UInt64)? {
        var ti = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size else { return nil }
        return (ti.pti_resident_size, machToNanos(ti.pti_total_user &+ ti.pti_total_system))
    }

    static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// task-info CPU times are Mach absolute-time ticks (1 ns on Intel, 125/3 ns on Apple Silicon).
    static func machToNanos(_ ticks: UInt64) -> UInt64 {
        let tb = timebase
        guard tb.denom != 0 else { return ticks }
        return UInt64((Double(ticks) * Double(tb.numer) / Double(tb.denom)).rounded())
    }

    /// Parent → grandparent → … → launchd (PID 1). Stops at a loop, a vanished process or 32 steps.
    public static func launcherChain(parent: pid_t, cache: ProcessCache = .shared) -> [Ancestor] {
        var chain: [Ancestor] = [], seen = Set<pid_t>(), pid = parent
        while pid > 0, chain.count < 32, seen.insert(pid).inserted, let bi = bsdInfo(pid) ?? kinfoInfo(pid) {
            chain.append(cache.ancestor(pid: pid, info: bi))
            if pid == 1 { break }
            pid = bi.ppid
        }
        return chain
    }

    /// Listening sockets plus, per local port, how many established TCP connections this process holds.
    public static func sockets(_ pid: pid_t) -> (listening: [BoundPort], established: [Int: Int]) {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return ([], [:]) }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return ([], [:]) }

        var listening: [BoundPort] = [], established: [Int: Int] = [:]
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let siSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, siSize) == siSize,
                  si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            let ini = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            if tcp.tcpsi_state == TSI_S_ESTABLISHED { established[port, default: 0] += 1; continue }
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let v4 = ini.insi_vflag & UInt8(INI_IPV4) != 0
            let exposure = v4 ? Exposure(ipv4: ini.insi_laddr.ina_46.i46a_addr4) : Exposure(ipv6: ini.insi_laddr.ina_6)
            let address = v4 ? ntop(AF_INET, ini.insi_laddr.ina_46.i46a_addr4) : ntop(AF_INET6, ini.insi_laddr.ina_6)
            listening.append(BoundPort(port: port, exposure: exposure, address: address))
        }
        return (listening, established)
    }

    /// Environment strings (`NAME=value`) of an own process. CLI only (`ports list --env`); the app never reads them.
    public static func environment(_ pid: pid_t) -> [String] { procArgs(pid).env }

    static func procArgs(_ pid: pid_t) -> (args: [String], env: [String]) {
        // Ask for the exact size first (usually a few KB) instead of a KERN_ARGMAX (1 MB) buffer per call,
        // which fragmented the heap of the long-running app.
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return ([], []) }
        return [UInt8](unsafeUninitializedCapacity: size) { buf, initialized in
            var n = size
            initialized = sysctl(&mib, 3, buf.baseAddress, &n, nil, 0) == 0 ? n : 0
        }.withUnsafeBufferPointer { parseProcArgs(Array($0)) }
    }
}

/// KERN_PROCARGS2 layout: [argc:int32][exec path\0][padding \0…][argv0\0]…[argvN\0][env0\0]…[\0]
func parseProcArgs(_ buf: [UInt8]) -> (args: [String], env: [String]) {
    guard buf.count > 4 else { return ([], []) }
    let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    var i = 4
    while i < buf.count && buf[i] != 0 { i += 1 }      // exec path
    while i < buf.count && buf[i] == 0 { i += 1 }      // padding
    var args: [String] = [], env: [String] = [], start = i
    while i < buf.count {
        if buf[i] == 0 {
            if i == start {                            // empty string: an empty argv entry, or the end of env
                if args.count >= argc { break }
                args.append("")
            } else {
                let s = String(decoding: buf[start..<i], as: UTF8.self)
                if args.count < argc { args.append(s) } else { env.append(s) }
            }
            start = i + 1
        }
        i += 1
    }
    return (args, env)
}

// MARK: - Static per-process data, cached by (pid, start time)

/// What does not change while a process lives, read once per process instance. Thread-safe.
public final class ProcessCache: @unchecked Sendable {
    public struct Static: Equatable, Sendable {
        public let exe: String
        public let argv: [String]
        public let cwd: String
        public let project: Project?
    }

    public static let shared = ProcessCache()
    private let lock = NSLock()
    private var statics: [String: Static] = [:]
    private var ancestors: [String: Ancestor] = [:]
    private var seen = Set<String>()
    let projects: ProjectResolver
    private let load: @Sendable (pid_t) -> (exe: String, argv: [String], cwd: String)

    public init(projects: ProjectResolver = ProjectResolver(),
                load: @escaping @Sendable (pid_t) -> (exe: String, argv: [String], cwd: String) = { pid in
        (Proc.exePath(pid), Proc.arguments(pid), Proc.cwd(pid))
    }) {
        self.projects = projects
        self.load = load
    }

    static func key(_ pid: pid_t, _ start: UInt64) -> String { "\(pid)-\(start)" }

    public func info(pid: pid_t, start: UInt64) -> Static {
        let k = Self.key(pid, start)
        lock.lock()
        seen.insert(k)
        if let s = statics[k] { lock.unlock(); return s }
        lock.unlock()
        let raw = load(pid)
        let s = Static(exe: raw.exe, argv: raw.argv, cwd: raw.cwd,
                       project: projects.resolve(cwd: raw.cwd, script: scriptArgument(exe: raw.exe, argv: raw.argv)))
        lock.lock(); statics[k] = s; lock.unlock()
        return s
    }

    func ancestor(pid: pid_t, info bi: BSDInfo) -> Ancestor {
        let k = Self.key(pid, bi.start)
        lock.lock()
        seen.insert(k)
        if let a = ancestors[k] { lock.unlock(); return a }
        lock.unlock()
        let argv0 = Proc.arguments(pid).first.map { basename($0) }
        let a = Ancestor(pid: pid, name: bi.name, exe: Proc.exePath(pid), command: argv0.flatMap { $0.isEmpty ? nil : $0 },
                         uid: bi.uid)
        lock.lock(); ancestors[k] = a; lock.unlock()
        return a
    }

    /// Drop entries not used since the previous call (processes that exited).
    public func endScan() {
        lock.lock(); defer { lock.unlock() }
        statics = statics.filter { seen.contains($0.key) }
        ancestors = ancestors.filter { seen.contains($0.key) }
        seen.removeAll(keepingCapacity: true)
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return statics.count }
}

// MARK: - CPU %

/// CPU % from two samples of total CPU time. Only sampled while the panel is open.
public final class CPUSampler: @unchecked Sendable {
    public static let shared = CPUSampler()
    private let lock = NSLock()
    private var last: [String: (cpu: UInt64, at: UInt64)] = [:]
    public init() {}

    /// `at` is a monotonic clock in ns. The first sample of a process returns nil.
    public func sample(key: String, cpuNanos: UInt64, at: UInt64) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let prev = last[key]
        last[key] = (cpuNanos, at)
        return prev.flatMap { cpuPercent(prevCPU: $0.cpu, prevAt: $0.at, cpu: cpuNanos, at: at) }
    }

    public func forget(keeping keys: Set<String>) {
        lock.lock(); last = last.filter { keys.contains($0.key) }; lock.unlock()
    }
}

/// 100 % = one core fully busy for the interval. nil for an empty or backwards interval.
public func cpuPercent(prevCPU: UInt64, prevAt: UInt64, cpu: UInt64, at: UInt64) -> Double? {
    guard at > prevAt, cpu >= prevCPU else { return nil }
    return Double(cpu - prevCPU) / Double(at - prevAt) * 100
}

// MARK: - Formatting

/// "running 45 s", "running 12 min", "running 3 h 5 min", "running 2 d 4 h".
public func formatUptime(_ seconds: Int) -> String {
    let s = max(0, seconds)
    switch s {
    case ..<60: return "running \(s) s"
    case ..<3600: return "running \(s / 60) min"
    case ..<86_400: return "running \(s / 3600) h \(s % 3600 / 60) min"
    default: return "running \(s / 86_400) d \(s % 86_400 / 3600) h"
    }
}

/// Seconds since a start time in µs.
public func uptimeSeconds(start: UInt64, now: Date = Date()) -> Int {
    Int(now.timeIntervalSince1970 - Double(start) / 1_000_000)
}

/// "12 MB", "1.3 GB".
public func formatBytes(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

// MARK: - Start command recall

/// POSIX single-quote unless every character is shell-safe.
public func shellQuote(_ s: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+=:,./-")
    if !s.isEmpty && s.unicodeScalars.allSatisfy(safe.contains) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// `cd '<cwd>' && <argv shell-quoted>`: what the user can paste to start the server again.
public func startCommand(cwd: String, argv: [String]) -> String {
    let cmd = argv.map(shellQuote).joined(separator: " ")
    return cwd.isEmpty ? cmd : "cd \(shellQuote(cwd)) && \(cmd)"
}

// MARK: - Environment (CLI only)

let secretNameParts = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASS", "AUTH", "CREDENTIAL", "PRIVATE",
                       "SESSION", "COOKIE", "SIGNATURE", "CERT", "DSN", "SALT"]

/// True when an environment value should never be printed in full.
public func looksSecret(name: String, value: String) -> Bool {
    let n = name.uppercased()
    if secretNameParts.contains(where: n.contains) { return true }
    if value.range(of: #"://[^/\s:@]+:[^/\s@]+@"#, options: .regularExpression) != nil { return true }  // user:pass@ URL
    // A long run of token characters without a path separator: API keys, JWTs, hashes.
    return value.count >= 24 && !value.contains("/")
        && value.range(of: #"^[A-Za-z0-9+=_.\-]+$"#, options: .regularExpression) != nil
}

/// `NAME=value` lines with secret-looking values replaced by `••••`.
public func maskedEnvironment(_ env: [String]) -> [String] {
    env.map { entry in
        guard let eq = entry.firstIndex(of: "=") else { return entry }
        let name = String(entry[..<eq]), value = String(entry[entry.index(after: eq)...])
        return looksSecret(name: name, value: value) ? "\(name)=••••" : entry
    }
}

// MARK: - Multi-worker grouping

/// Listeners on one port whose process descends from another listener of that port and holds the same
/// inherited socket (same uid, a shared bind address) fold into the topmost one: gunicorn and uvicorn workers,
/// prefork servers. Unrelated owners (IPv4 + IPv6, SO_REUSEPORT siblings, a child on another address) stay rows.
public func groupWorkers(_ ls: [Listener]) -> [Listener] {
    var owners: [Int: [pid_t: Listener]] = [:]
    for l in ls { owners[l.port, default: [:]][l.pid] = l }
    func root(_ l: Listener) -> pid_t? {
        let onPort = owners[l.port] ?? [:]
        return ([l.ppid] + l.chain.map(\.pid)).last { pid in                // topmost listening ancestor
            guard pid != l.pid, let r = onPort[pid] else { return false }
            return r.uid == l.uid && !Set(r.addresses).isDisjoint(with: l.addresses)
        }
    }
    var workersOf: [String: [Listener]] = [:]
    var keep: [Listener] = []
    for l in ls {
        if let r = root(l) { workersOf["\(r)-\(l.port)", default: []].append(l) } else { keep.append(l) }
    }
    return keep.map { l in
        guard let ws = workersOf["\(l.pid)-\(l.port)"] else { return l }
        var g = l
        g.workers = ws.map(\.pid).sorted()
        g.connections += ws.reduce(0) { $0 + $1.connections }
        return g
    }
}
