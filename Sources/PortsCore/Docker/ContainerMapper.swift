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
