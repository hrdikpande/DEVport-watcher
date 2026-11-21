// Phase 6: find every container runtime's Engine API socket. File checks only; nothing is contacted here.
import Darwin
import Foundation

public struct ContainerRuntime: Equatable, Sendable, Hashable {
    public let name: String        // "Docker Desktop", "OrbStack", "Colima (default)", "Podman", …
    public let family: String      // matches `containerRuntime(exe:)`: Docker, OrbStack, Colima/Lima, Rancher Desktop, Podman
    public let socket: String
}

/// `unix:///path` -> "/path"; nil for tcp:// and anything else (Ports only talks to local sockets).
public func unixSocketPath(_ host: String) -> String? {
    guard host.hasPrefix("unix://") else { return nil }
    let p = String(host.dropFirst("unix://".count))
    return p.hasPrefix("/") ? p : nil
}

func isSocket(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
}

/// Follow symlinks (e.g. /var/run/docker.sock -> ~/.docker/run/docker.sock), then check it is a socket.
func resolvedSocket(_ path: String) -> String? {
    let resolved = (path as NSString).resolvingSymlinksInPath
    return isSocket(resolved) ? resolved : nil
}

/// Name a runtime from where its socket lives.
public func runtimeFor(socket: String, home: String = PortsCore.home) -> ContainerRuntime {
    let p = socket
    func rt(_ n: String, _ f: String) -> ContainerRuntime { ContainerRuntime(name: n, family: f, socket: socket) }
    if p.hasPrefix(home + "/.orbstack/") { return rt("OrbStack", "OrbStack") }
    if p.hasPrefix(home + "/.colima/") {
        let profile = p.dropFirst((home + "/.colima/").count).split(separator: "/").first.map(String.init) ?? "default"
        return rt("Colima (\(profile))", "Colima/Lima")
    }
    if p.hasPrefix(home + "/.lima/") {
        let inst = p.dropFirst((home + "/.lima/").count).split(separator: "/").first.map(String.init) ?? "default"
        return rt("Lima (\(inst))", "Colima/Lima")
    }
    if p.hasPrefix(home + "/.rd/") { return rt("Rancher Desktop", "Rancher Desktop") }
    if p.contains("podman") { return rt("Podman", "Podman") }
    if p.hasPrefix(home + "/.docker/") { return rt("Docker Desktop", "Docker") }
    return rt("Docker", "Docker")
}

/// The Docker CLI's current context endpoint (`~/.docker/config.json` + `contexts/meta/*/meta.json`).
public func currentContextSocket(home: String = PortsCore.home) -> String? {
    let fm = FileManager.default
    guard let cfg = fm.contents(atPath: home + "/.docker/config.json"),
          let json = try? JSONSerialization.jsonObject(with: cfg) as? [String: Any],
          let current = json["currentContext"] as? String, current != "default" else { return nil }
    let metaDir = home + "/.docker/contexts/meta"
    for dir in (try? fm.contentsOfDirectory(atPath: metaDir)) ?? [] {
        guard let data = fm.contents(atPath: "\(metaDir)/\(dir)/meta.json"),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              meta["Name"] as? String == current,
              let host = ((meta["Endpoints"] as? [String: Any])?["docker"] as? [String: Any])?["Host"] as? String
        else { continue }
        return unixSocketPath(host)
    }
    return nil
}

/// Every socket that exists, in the spec's order, deduplicated by where it really points.
public func locateRuntimes(home: String = PortsCore.home,
                           env: [String: String] = ProcessInfo.processInfo.environment,
                           tmp: String = NSTemporaryDirectory()) -> [ContainerRuntime] {
    let fm = FileManager.default
    var candidates: [String] = []
    if let h = env["DOCKER_HOST"], let p = unixSocketPath(h) { candidates.append(p) }
    if let p = currentContextSocket(home: home) { candidates.append(p) }
    candidates += [home + "/.docker/run/docker.sock", "/var/run/docker.sock", home + "/.orbstack/run/docker.sock"]
    for profile in (try? fm.contentsOfDirectory(atPath: home + "/.colima"))?.sorted() ?? [] {
        candidates.append("\(home)/.colima/\(profile)/docker.sock")
    }
    for inst in (try? fm.contentsOfDirectory(atPath: home + "/.lima"))?.sorted() ?? [] {
        candidates.append("\(home)/.lima/\(inst)/sock/docker.sock")
    }
    candidates.append(home + "/.rd/docker.sock")
    // Podman machine: 4.x keeps its socket under ~/.local/share; 5.x uses $TMPDIR/podman/<machine>-api.sock.
    let podmanRoot = home + "/.local/share/containers/podman/machine"
    if let e = fm.enumerator(atPath: podmanRoot) {
        while let rel = e.nextObject() as? String {
            if rel.hasSuffix("podman.sock") || rel.hasSuffix("-api.sock") { candidates.append(podmanRoot + "/" + rel) }
            if e.level > 4 { e.skipDescendants() }
        }
    }
    let podmanTmp = (tmp as NSString).appendingPathComponent("podman")
    for f in (try? fm.contentsOfDirectory(atPath: podmanTmp))?.sorted() ?? [] where f.hasSuffix("-api.sock") {
        candidates.append(podmanTmp + "/" + f)
    }
    var seen = Set<String>(), out: [ContainerRuntime] = []
    for c in candidates {
        guard let real = resolvedSocket(c), seen.insert(real).inserted else { continue }
        let named = runtimeFor(socket: real, home: home)
        out.append(ContainerRuntime(name: named.name, family: named.family, socket: c))
    }
    return out
}
