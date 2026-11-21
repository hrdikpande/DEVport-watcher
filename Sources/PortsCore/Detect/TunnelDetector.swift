// Phase 8: tunnels and forwards — detected and displayed, never managed. Public URLs come from the
// tools' own local APIs (ngrok :4040, cloudflared's metrics /quicktunnel), read only while the panel
// is open, loopback only, read-only.
import Darwin
import Foundation

public struct TunnelInfo: Equatable, Sendable {
    public let kind: String          // ssh, ngrok, cloudflared, kubectl, gcloud, aws-ssm, cloud-sql-proxy, tailscale
    public let summary: String       // "Forward → db.internal:5432", "k8s · svc/web 8080→80"
    public var publicURL: String?
}

// MARK: - SSH

public struct SSHForward: Equatable, Sendable {
    public enum Kind: String, Sendable { case local = "L", remote = "R", dynamic = "D" }
    public let kind: Kind
    public let bind: String?
    public let port: Int
    public let host: String?
    public let hostPort: Int?
    /// "Forward → db:5432", "SOCKS proxy", "Reverse: remote :8080 → localhost:3000"
    public var summary: String {
        switch kind {
        case .local: return "Forward → \(host ?? "?"):\(hostPort ?? 0)"
        case .dynamic: return "SOCKS proxy (ssh -D)"
        case .remote: return "Reverse: remote :\(port) → \(host ?? "localhost"):\(hostPort ?? 0)"
        }
    }
}

/// Split "[bind:]port:host:hostport" (IPv6 in brackets) into parts.
func forwardParts(_ spec: String) -> [String] {
    var parts: [String] = [], cur = "", depth = 0
    for ch in spec {
        if ch == "[" { depth += 1; continue }
        if ch == "]" { depth -= 1; continue }
        if ch == ":" && depth == 0 { parts.append(cur); cur = ""; continue }
        cur.append(ch)
    }
    parts.append(cur)
    return parts
}

/// `ssh -L [bind:]port:host:hostport`, `-R …`, `-D [bind:]port`, also glued (`-L8080:db:80`). Unix-socket forms are skipped.
public func parseSSHForwards(_ argv: [String]) -> [SSHForward] {
    var out: [SSHForward] = []
    var i = 1
    let valueFlags: Set<Character> = ["b", "c", "E", "e", "F", "I", "i", "J", "l", "m", "O", "o", "p", "Q", "S", "W", "w", "B"]
    while i < argv.count {
        let a = argv[i]
        guard a.hasPrefix("-"), a.count >= 2 else { i += 1; continue }
        let flag = a[a.index(after: a.startIndex)]
        var spec: String?
        if ["L", "R", "D"].contains(flag) {
            if a.count > 2 { spec = String(a.dropFirst(2)) } else if i + 1 < argv.count { spec = argv[i + 1]; i += 1 }
        } else if valueFlags.contains(flag) && a.count == 2 { i += 1 }        // skip the flag's value
        i += 1
        guard let spec, !spec.contains("/") else { continue }
        let p = forwardParts(spec)
        switch flag {
        case "D":
            if let port = Int(p.last ?? "") { out.append(SSHForward(kind: .dynamic, bind: p.count > 1 ? p[0] : nil, port: port, host: nil, hostPort: nil)) }
        case "L", "R":
            let k: SSHForward.Kind = flag == "L" ? .local : .remote
            if p.count == 4, let port = Int(p[1]), let hp = Int(p[3]) {
                out.append(SSHForward(kind: k, bind: p[0].isEmpty ? nil : p[0], port: port, host: p[2], hostPort: hp))
            } else if p.count == 3, let port = Int(p[0]), let hp = Int(p[2]) {
                out.append(SSHForward(kind: k, bind: nil, port: port, host: p[1], hostPort: hp))
            }
        default: break
        }
    }
    return out
}

// MARK: - kubectl and cloud forwarders

public struct KubeForward: Equatable, Sendable {
    public let resource: String
    public let namespace: String?
    public let ports: [(local: Int, remote: Int)]
    public static func == (a: Self, b: Self) -> Bool {
        a.resource == b.resource && a.namespace == b.namespace && a.ports.map { [$0.local, $0.remote] } == b.ports.map { [$0.local, $0.remote] }
    }
    public func summary(local: Int) -> String {
        let remote = ports.first { $0.local == local }?.remote ?? ports.first?.remote ?? 0
        return "k8s · \(namespace.map { "\($0)/" } ?? "")\(resource) \(local)→\(remote)"
    }
}

/// `kubectl port-forward [-n ns] TYPE/NAME [LOCAL:]REMOTE … [--address …]`. ":REMOTE" (random local) has local 0.
public func parseKubectlPortForward(_ argv: [String]) -> KubeForward? {
    guard let pf = argv.firstIndex(of: "port-forward") else { return nil }
    var ns: String?, resource: String?, ports: [(Int, Int)] = []
    var i = pf + 1
    while i < argv.count {
        let a = argv[i]
        if a == "-n" || a == "--namespace" { ns = i + 1 < argv.count ? argv[i + 1] : nil; i += 2; continue }
        if a.hasPrefix("--namespace=") { ns = String(a.dropFirst("--namespace=".count)); i += 1; continue }
        if a == "--address" || a == "--context" || a == "--kubeconfig" || a == "--pod-running-timeout" { i += 2; continue }
        if a.hasPrefix("-") { i += 1; continue }
        if resource == nil { resource = a; i += 1; continue }
        let p = a.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if p.count == 1, let n = Int(p[0]) { ports.append((n, n)) }
        else if p.count == 2, let r = Int(p[1]) { ports.append((Int(p[0]) ?? 0, r)) }
        i += 1
    }
    guard let resource else { return nil }
    return KubeForward(resource: resource.contains("/") ? resource : "pod/\(resource)", namespace: ns, ports: ports)
}

func flagValue(_ argv: [String], _ names: [String]) -> String? {
    for (i, a) in argv.enumerated() {
        for n in names {
            if a == n, i + 1 < argv.count { return argv[i + 1] }
            if a.hasPrefix(n + "=") { return String(a.dropFirst(n.count + 1)) }
        }
    }
    return nil
}

/// cloudflared: a quick tunnel's local target (`tunnel --url http://localhost:3000`) or a named tunnel.
public func parseCloudflared(_ argv: [String]) -> (target: URL?, named: String?) {
    let target = flagValue(argv, ["--url"]).flatMap(URL.init(string:))
    var named: String?
    if let run = argv.firstIndex(of: "run"), argv.contains("tunnel") {
        named = argv[(run + 1)...].first { !$0.hasPrefix("-") }
    }
    return (target, named)
}

/// What a tunnel/forward process itself does, from its argv. Display only.
public func tunnelInfo(for l: Listener) -> TunnelInfo? {
    let names = identityNames(exe: l.exe, argv: l.argv)
    func has(_ n: String) -> Bool { names.contains { nameMatches($0, n) } }
    if has("ssh") {
        let fs = parseSSHForwards(l.argv)
        let mine = fs.first { $0.kind != .remote && $0.port == l.port } ?? fs.first { $0.kind != .remote }
        let host = l.argv.dropFirst().last { !$0.hasPrefix("-") } ?? "ssh"
        return TunnelInfo(kind: "ssh", summary: (mine?.summary ?? "SSH") + " via \(host)", publicURL: nil)
    }
    if has("kubectl"), let k = parseKubectlPortForward(l.argv) { return TunnelInfo(kind: "kubectl", summary: k.summary(local: l.port), publicURL: nil) }
    if has("ngrok") { return TunnelInfo(kind: "ngrok", summary: "ngrok agent", publicURL: nil) }
    if has("cloudflared") {
        let c = parseCloudflared(l.argv)
        let what = c.named.map { "named tunnel \($0)" } ?? c.target.map { "quick tunnel → \($0.host ?? "localhost"):\($0.port ?? 80)" } ?? "tunnel"
        return TunnelInfo(kind: "cloudflared", summary: "cloudflared " + what, publicURL: nil)
    }
    if has("gcloud") {
        let inst = l.argv.firstIndex(of: "start-iap-tunnel").flatMap { $0 + 1 < l.argv.count ? l.argv[$0 + 1] : nil }
        return TunnelInfo(kind: "gcloud", summary: "gcloud IAP tunnel" + (inst.map { " → \($0)" } ?? ""), publicURL: nil)
    }
    if has("session-manager-plugin") {
        let remote = l.argv.joined(separator: " ").range(of: #""portNumber"\s*:\s*\[?"?(\d+)"#, options: .regularExpression)
            .map { String(l.argv.joined(separator: " ")[$0]).filter(\.isNumber) }
        return TunnelInfo(kind: "aws-ssm", summary: "AWS SSM port forward" + (remote.map { " → :\($0)" } ?? ""), publicURL: nil)
    }
    if has("cloud-sql-proxy") || has("cloud_sql_proxy") {
        let inst = l.argv.dropFirst().first { $0.split(separator: ":").count == 3 }
        return TunnelInfo(kind: "cloud-sql-proxy", summary: "Cloud SQL proxy" + (inst.map { " → \($0)" } ?? ""), publicURL: nil)
    }
    if has("tailscaled") || has("tailscale") { return TunnelInfo(kind: "tailscale", summary: "Tailscale serve/funnel", publicURL: nil) }
    return nil
}

// MARK: - Public URLs (ngrok, cloudflared) and reverse forwards

/// ngrok agent `/api/tunnels`: public URL by forwarded local port.
public func parseNgrokTunnels(_ json: Data) -> [Int: String] {
    guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
          let tunnels = root["tunnels"] as? [[String: Any]] else { return [:] }
    var out: [Int: String] = [:]
    for t in tunnels {
        guard let url = t["public_url"] as? String, let addr = (t["config"] as? [String: Any])?["addr"] as? String else { continue }
        let port = URL(string: addr.contains("://") ? addr : "http://\(addr)")?.port ?? Int(addr)
        if let port, out[port] == nil || url.hasPrefix("https") { out[port] = url }
    }
    return out
}

/// cloudflared metrics `/quicktunnel`: {"hostname": "x.trycloudflare.com"}.
public func parseQuickTunnel(_ json: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
          let h = root["hostname"] as? String, !h.isEmpty,
          h.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else { return nil }
    return "https://" + h
}

/// Local ports exposed elsewhere by `ssh -R` from any of your ssh processes: local port -> note.
public func reverseForwards(_ argvs: [[String]]) -> [Int: String] {
    var out: [Int: String] = [:]
    for argv in argvs {
        let host = argv.dropFirst().last { !$0.hasPrefix("-") } ?? "remote"
        for f in parseSSHForwards(argv) where f.kind == .remote {
            if let hp = f.hostPort, ["localhost", "127.0.0.1", "::1", nil].contains(f.host) {
                out[hp] = "Reachable on \(host) :\(f.port) (ssh -R)"
            }
        }
    }
    return out
}

/// Public URLs per local port, from the tunnel agents' local APIs (menu open only). Cached per agent instance.
public final class TunnelProbeCache: @unchecked Sendable {
    public static let shared = TunnelProbeCache()
    private let lock = NSLock()
    private var byAgent: [String: [Int: String]] = [:]       // listenerKey of the agent's API port -> local port -> URL
    private let fetch: @Sendable (Int, String) -> Data?
    public init(fetch: @escaping @Sendable (Int, String) -> Data? = { port, path in
        loopbackHTTP(port: port, path: path).flatMap { $0.status == 200 ? $0.body : nil }
    }) { self.fetch = fetch }

    /// Fill `tunnel` on tunnel rows and `exposedVia` on the rows whose port a tunnel forwards.
    public func apply(_ ls: [Listener], probe: Bool, reverse: [Int: String] = [:]) -> [Listener] {
        var ls = ls.map { l -> Listener in
            var r = l
            if r.baseKind == .tunnel, let info = tunnelInfo(for: l) { r.tunnel = info; r.label = info.summary }
            return r
        }
        if probe {
            for l in ls where l.tunnel?.kind == "ngrok" || l.tunnel?.kind == "cloudflared" {
                let key = listenerKey(l)
                lock.lock(); let seen = byAgent[key] != nil; lock.unlock()
                guard !seen else { continue }
                var found: [Int: String] = [:]
                if l.tunnel?.kind == "ngrok", let d = fetch(l.port, "/api/tunnels") { found = parseNgrokTunnels(d) }
                if l.tunnel?.kind == "cloudflared", let d = fetch(l.port, "/quicktunnel"), let url = parseQuickTunnel(d),
                   let target = parseCloudflared(l.argv).target?.port {
                    found = [target: url]
                }
                lock.lock(); byAgent[key] = found; lock.unlock()
            }
        }
        lock.lock()
        let live = Set(ls.map(listenerKey))
        byAgent = byAgent.filter { live.contains($0.key) }
        let agents = byAgent
        lock.unlock()
        var urls: [Int: (url: String, via: String)] = [:]
        for l in ls { for (port, url) in agents[listenerKey(l)] ?? [:] { urls[port] = (url, l.tunnel?.kind ?? "tunnel") } }
        for i in ls.indices {
            if let u = urls[ls[i].port], ls[i].baseKind != .tunnel { ls[i].exposedVia = "\(u.via) → \(u.url)"; ls[i].publicURL = u.url }
            else if let r = reverse[ls[i].port] { ls[i].exposedVia = r }
            if ls[i].tunnel?.kind == "cloudflared", let t = parseCloudflared(ls[i].argv).target?.port, let u = urls[t] {
                ls[i].tunnel?.publicURL = u.url
            }
            if ls[i].tunnel?.kind == "ngrok", let first = agents[listenerKey(ls[i])]?.values.sorted().first {
                ls[i].tunnel?.publicURL = first
            }
        }
        return ls
    }
}

/// argv of your ssh processes (for `ssh -R`), read through the cache.
public func sshArgvs(cache: ProcessCache = .shared, procs: [Proc.Brief] = Proc.all(uid: getuid())) -> [[String]] {
    procs.filter { $0.name == "ssh" }.compactMap { p in
        Proc.bsdInfo(p.pid).map { cache.info(pid: p.pid, start: $0.start).argv }
    }
}
