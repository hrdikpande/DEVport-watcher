import Darwin
import Foundation

// MARK: - Scan (runs off the main thread)

/// One scan of every listening socket. Static per-process data comes from `cache` (keyed by pid + start
/// time); what can change (ppid, state, TTY, metrics, connections, branch) is read every time.
/// `sampleCPU` (panel open only) adds CPU % from the previous sample.
public func scan(docker: [Int: String], containers: [Int: [ContainerInfo]] = [:], cache: ProcessCache = .shared, sampleCPU: Bool = false,
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
            if let info = containerInfo(exe: exe, port: port, map: containers) {
                l.container = info.name
                l.containerInfo = info
            }
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
            l.label = l.containerInfo?.label ?? rowLabel(kind: c.kind, tool: c.name, cwd: cwd, project: project)
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
    guard let snap = ContainerDirectory.shared.current(listeners: first, maxAge: 0) else { return first }
    return scan(docker: snap.namesByPort, containers: snap.byPort)
}

/// Bound UDP sockets (CLI `ports list --udp`): read-only, one row per process and port.
public func scanUDP(cache: ProcessCache = .shared) -> [Listener] {
    var out: [Listener] = []
    for pid in Proc.allPIDs() {
        let socks = Proc.udpSockets(pid)
        guard !socks.isEmpty, let bsd = Proc.bsdInfo(pid) else { continue }
        let info = cache.info(pid: pid, start: bsd.start)
        var byPort: [Int: (Exposure, [String])] = [:]
        for b in socks {
            let cur = byPort[b.port]
            byPort[b.port] = (cur.map { $0.0.widest(b.exposure) } ?? b.exposure, (cur?.1 ?? []) + [b.address])
        }
        for (port, (exposure, addrs)) in byPort {
            var l = Listener(port: port, pid: pid, start: bsd.start, uid: bsd.uid, exposed: exposure.isNetworkReachable,
                             exposure: exposure, exe: info.exe, command: info.argv.joined(separator: " "),
                             argv: info.argv.isEmpty ? [info.exe] : info.argv, cwd: info.cwd)
            l.proto = "udp"
            l.addresses = Array(Set(addrs)).sorted()
            l.ppid = bsd.ppid
            let c = classifyDetailed(l)
            l.kind = c.kind; l.framework = c.framework?.name; l.confidence = c.confidence; l.tier = c.tier
            l.label = rowLabel(kind: c.kind, tool: c.name, cwd: info.cwd, project: info.project)
            out.append(l)
        }
    }
    return out.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
}
