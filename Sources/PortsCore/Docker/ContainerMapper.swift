import Darwin
import Foundation

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
public func dockerPorts() -> [Int: String] { dockerQuery() ?? [:] }

/// nil when the runtime didn't answer (so Doctor can say so), else host port -> container name.
public func dockerQuery() -> [Int: String]? {
    guard let docker = dockerPath else { return nil }
    let res = run(docker, ["ps", "--format", "{{.Names}}\t{{.Ports}}"])
    return res.ok ? parseDockerPorts(res.out) : nil
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

// MARK: - Phase 6: Engine API directory

/// Containers by published host port.
public func containerMap(_ cs: [ContainerInfo]) -> [Int: [ContainerInfo]] {
    var m: [Int: [ContainerInfo]] = [:]
    for c in cs where c.state == "running" || c.state.isEmpty {
        for p in Set(c.ports.map(\.publicPort)) { m[p, default: []].append(c) }
    }
    return m
}

/// The container behind a listener: only a runtime's proxy can own a published port; with several
/// runtimes, the one whose proxy this is wins.
public func containerInfo(exe: String, port: Int, map: [Int: [ContainerInfo]]) -> ContainerInfo? {
    guard let family = containerRuntime(exe: exe), let cs = map[port], !cs.isEmpty else { return nil }
    return cs.first { $0.runtime?.family == family } ?? cs.first
}

public struct ContainerSnapshot: Sendable {
    public let runtimes: [ContainerRuntime]        // sockets found
    public let answered: [ContainerRuntime]        // sockets whose engine answered
    public let containers: [ContainerInfo]
    public let viaCLI: Bool                        // no socket answered; the CLI fallback was used
    public let at: Date
    public var byPort: [Int: [ContainerInfo]] { containerMap(containers) }
    public var namesByPort: [Int: String] { byPort.mapValues { $0[0].name } }
    /// false when a runtime exists but nothing answered (Doctor says so).
    public var reachable: Bool { !answered.isEmpty || viaCLI }
    public func project(_ name: String) -> [ContainerInfo] { containers.filter { $0.project == name }.sorted { $0.name < $1.name } }
    public func named(_ name: String) -> ContainerInfo? { containers.first { $0.name == name } }
}

/// Queries the engines only when a runtime's proxy is listening: on every open-menu scan (maxAge 0), at most
/// every 15 s otherwise, and at once when the set of proxy listeners changes. Thread-safe.
public final class ContainerDirectory: @unchecked Sendable {
    public static let shared = ContainerDirectory()
    private let lock = NSLock()
    private var cached: ContainerSnapshot?
    private var proxySignature = ""
    private let locate: @Sendable () -> [ContainerRuntime]
    private let cli: @Sendable () -> [Int: String]?

    public init(locate: @escaping @Sendable () -> [ContainerRuntime] = { locateRuntimes() },
                cli: @escaping @Sendable () -> [Int: String]? = { dockerQuery() }) {
        self.locate = locate
        self.cli = cli
    }

    public var last: ContainerSnapshot? { lock.lock(); defer { lock.unlock() }; return cached }

    public func current(listeners: [Listener], maxAge: TimeInterval, now: Date = Date()) -> ContainerSnapshot? {
        let proxies = listeners.filter { containerRuntime(exe: $0.exe) != nil }
        guard !proxies.isEmpty else { return nil }
        let sig = proxies.map { "\($0.pid):\($0.port)" }.sorted().joined(separator: ",")
        lock.lock()
        if let c = cached, sig == proxySignature, now.timeIntervalSince(c.at) < maxAge { lock.unlock(); return c }
        lock.unlock()
        let snap = query(now: now)
        lock.lock(); cached = snap; proxySignature = sig; lock.unlock()
        return snap
    }

    func query(now: Date) -> ContainerSnapshot {
        let runtimes = locate()
        var answered: [ContainerRuntime] = [], all: [ContainerInfo] = []
        for rt in runtimes {
            guard let r = unixHTTP(socket: rt.socket, path: "/containers/json"), r.status == 200 else { continue }
            answered.append(rt)
            all += parseContainers(r.body, runtime: rt)
        }
        if answered.isEmpty, let names = cli() {
            // CLI fallback (fixed paths): names and ports only.
            var byName: [String: [Int]] = [:]
            for (port, name) in names { byName[name, default: []].append(port) }
            all = byName.map { name, ports in
                ContainerInfo(id: "", name: name, image: "", state: "running", status: "", project: nil, service: nil,
                              ports: ports.map { PublishedPort(ip: "", privatePort: 0, publicPort: $0, proto: "tcp") }, runtime: nil)
            }
            return ContainerSnapshot(runtimes: runtimes, answered: [], containers: all, viaCLI: true, at: now)
        }
        return ContainerSnapshot(runtimes: runtimes, answered: answered, containers: all, viaCLI: false, at: now)
    }
}

/// Stop or restart a container: through its engine's API when known, else the CLI (fixed path).
public func containerAction(_ action: String, name: String, directory: ContainerDirectory = .shared) -> String? {
    guard ["stop", "restart"].contains(action), isSafeContainerName(name) else { return "Unsafe container name." }
    if let c = directory.last?.named(name), !c.id.isEmpty, let socket = c.runtime?.socket {
        return engineContainerAction(action, id: c.id, socket: socket)?.description
    }
    guard let docker = dockerPath else { return "No container engine or CLI was found." }
    let r = run(docker, [action, "--", name], timeout: 30)
    return r.ok ? nil : r.out
}

/// `docker logs -f <name>` for the clipboard.
public func logsCommand(_ name: String) -> String { "docker logs -f " + shellQuote(name) }
