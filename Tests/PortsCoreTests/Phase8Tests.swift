import Darwin
import Foundation
import Testing
@testable import PortsCore

func tunnelRow(_ exe: String, _ argv: [String], port: Int) -> Listener {
    var l = Listener(port: port, pid: 5000 + pid_t(port % 1000), start: 1, uid: getuid(), exposed: false, exe: exe,
                     command: argv.joined(separator: " "), argv: argv, cwd: "/tmp")
    let c = classifyDetailed(l)
    l.kind = c.kind
    l.framework = c.framework?.name
    return l
}

final class FetchLog: @unchecked Sendable {
    private let lock = NSLock(); private var calls: [String] = []
    func add(_ s: String) { lock.lock(); calls.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return calls }
}

@Suite("Phase 8 · Parsing forwards")
struct ForwardParsingTests {
    static let sshCases: [([String], [SSHForward])] = [
        (["ssh", "-N", "-L", "15432:db:5432", "bastion"], [SSHForward(kind: .local, bind: nil, port: 15432, host: "db", hostPort: 5432)]),
        (["ssh", "-L8080:localhost:80", "h"], [SSHForward(kind: .local, bind: nil, port: 8080, host: "localhost", hostPort: 80)]),
        (["ssh", "-L", "127.0.0.1:9000:api:9000", "h"], [SSHForward(kind: .local, bind: "127.0.0.1", port: 9000, host: "api", hostPort: 9000)]),
        (["ssh", "-L", "[::1]:9001:host:22", "h"], [SSHForward(kind: .local, bind: "::1", port: 9001, host: "host", hostPort: 22)]),
        (["ssh", "-D", "1080", "h"], [SSHForward(kind: .dynamic, bind: nil, port: 1080, host: nil, hostPort: nil)]),
        (["ssh", "-D", "127.0.0.1:1081", "h"], [SSHForward(kind: .dynamic, bind: "127.0.0.1", port: 1081, host: nil, hostPort: nil)]),
        (["ssh", "-R", "8080:localhost:3000", "h"], [SSHForward(kind: .remote, bind: nil, port: 8080, host: "localhost", hostPort: 3000)]),
        (["ssh", "-L", "/tmp/demo.sock:host:80", "h"], []),                                  // unix socket form: skipped
        (["ssh", "-p", "2222", "-o", "ServerAliveInterval=30", "-L", "1:a:2", "-L", "3:b:4", "h"],
         [SSHForward(kind: .local, bind: nil, port: 1, host: "a", hostPort: 2), SSHForward(kind: .local, bind: nil, port: 3, host: "b", hostPort: 4)]),
        (["ssh", "h"], []),
    ]
    @Test("ssh -L / -R / -D", arguments: sshCases)
    func ssh(argv: [String], expected: [SSHForward]) { #expect(parseSSHForwards(argv) == expected) }

    @Test("kubectl port-forward")
    func kubectl() {
        let a = parseKubectlPortForward(["kubectl", "port-forward", "svc/web", "8080:80"])
        #expect(a?.summary(local: 8080) == "k8s · svc/web 8080→80")
        let b = parseKubectlPortForward(["kubectl", "port-forward", "-n", "shop", "deploy/api", "9000", "--address", "0.0.0.0"])
        #expect(b?.summary(local: 9000) == "k8s · shop/deploy/api 9000→9000")
        let c = parseKubectlPortForward(["kubectl", "--context", "dev", "port-forward", "web-7d9f", ":5432"])
        #expect(c?.resource == "pod/web-7d9f" && c?.ports.first?.local == 0 && c?.ports.first?.remote == 5432)
        #expect(parseKubectlPortForward(["kubectl", "get", "pods"]) == nil)
    }

    @Test("cloudflared quick and named tunnels")
    func cloudflared() {
        let q = parseCloudflared(["cloudflared", "tunnel", "--url", "http://localhost:3000"])
        #expect(q.target?.port == 3000 && q.named == nil)
        let n = parseCloudflared(["cloudflared", "tunnel", "--config", "/tmp/demo.yml", "run", "demo-tunnel"])
        #expect(n.named == "demo-tunnel")
    }

    @Test("ngrok and cloudflared local APIs")
    func apis() {
        let ngrok = Data(#"{"tunnels":[{"public_url":"http://a.example","config":{"addr":"http://localhost:3000"}},{"public_url":"https://a.example","config":{"addr":"http://localhost:3000"}},{"public_url":"tcp://0.tcp.example:1","config":{"addr":"localhost:5432"}}]}"#.utf8)
        #expect(parseNgrokTunnels(ngrok) == [3000: "https://a.example", 5432: "tcp://0.tcp.example:1"])
        #expect(parseNgrokTunnels(Data("{}".utf8)).isEmpty)
        #expect(parseQuickTunnel(Data(#"{"hostname":"demo-word.trycloudflare.com"}"#.utf8)) == "https://demo-word.trycloudflare.com")
        #expect(parseQuickTunnel(Data(#"{"hostname":"evil.example/../x"}"#.utf8)) == nil)
        #expect(parseQuickTunnel(Data(#"{"hostname":""}"#.utf8)) == nil)
    }

    @Test("ssh -R from any ssh process marks the local port it exposes")
    func reverse() {
        let r = reverseForwards([["ssh", "-N", "-R", "8080:localhost:3000", "bastion.example"], ["ssh", "-R", "9:db:5432", "x"]])
        #expect(r == [3000: "Reachable on bastion.example :8080 (ssh -R)"])
    }
}

@Suite("Phase 8 · Tunnel rows")
struct TunnelRowTests {
    @Test("Forwarders are Tunnels & forwards and render what they forward", arguments: [
        ("/usr/bin/ssh", ["ssh", "-N", "-L", "15432:db:5432", "bastion"], 15432, "Forward → db:5432 via bastion"),
        ("/opt/demo/bin/kubectl", ["kubectl", "port-forward", "svc/name", "8080:80"], 8080, "k8s · svc/name 8080→80"),
        ("/opt/demo/bin/cloudflared", ["cloudflared", "tunnel", "--url", "http://localhost:3000"], 20241,
         "cloudflared quick tunnel → localhost:3000"),
        ("/opt/demo/bin/cloud-sql-proxy", ["cloud-sql-proxy", "demo-proj:us-central1:db", "--port", "5432"], 5432,
         "Cloud SQL proxy → demo-proj:us-central1:db"),
        ("/opt/demo/bin/session-manager-plugin", ["session-manager-plugin", #"{"portNumber":["5432"],"localPortNumber":["15433"]}"#], 15433,
         "AWS SSM port forward → :5432"),
        ("/opt/demo/bin/ngrok", ["ngrok", "http", "3000"], 4040, "ngrok agent"),
    ] as [(String, [String], Int, String)])
    func rows(exe: String, argv: [String], port: Int, summary: String) {
        let l = tunnelRow(exe, argv, port: port)
        #expect(l.kind == .tunnel)
        #expect(tunnelInfo(for: l)?.summary == summary)
        #expect(!isWebCandidate(l))                                       // forwards are never probed as web servers
        #expect(stopMethods(l, starter: Starter(kind: .unknown, name: "unknown", pid: nil), ctx: supCtx()) == [.signal(StopTarget(l))])
    }

    @Test("Public URLs are read only when probing, once per agent, and land on the forwarded row")
    func publicURLs() {
        let log = FetchLog()
        let cache = TunnelProbeCache(fetch: { port, path in
            log.add("\(port)\(path)")
            if path == "/api/tunnels" { return Data(#"{"tunnels":[{"public_url":"https://demo.ngrok.example","config":{"addr":"http://localhost:3000"}}]}"#.utf8) }
            if path == "/quicktunnel" { return Data(#"{"hostname":"demo.trycloudflare.com"}"#.utf8) }
            return nil
        })
        let agent = tunnelRow("/opt/demo/bin/ngrok", ["ngrok", "http", "3000"], port: 4040)
        let cf = tunnelRow("/opt/demo/bin/cloudflared", ["cloudflared", "tunnel", "--url", "http://localhost:5173"], port: 20241)
        var vite = tunnelRow("/usr/local/bin/vite", ["vite"], port: 3000)
        vite.kind = .frontend
        var other = tunnelRow("/usr/local/bin/vite", ["vite"], port: 5173)
        other.kind = .frontend
        let closed = cache.apply([agent, vite], probe: false)
        #expect(log.all.isEmpty)                                          // menu closed: never asked
        #expect(closed[0].tunnel?.summary == "ngrok agent" && closed[1].exposedVia == nil)
        let open = cache.apply([agent, vite, cf, other], probe: true)
        #expect(open[1].exposedVia == "ngrok → https://demo.ngrok.example")
        #expect(open[0].tunnel?.publicURL == "https://demo.ngrok.example")
        #expect(open[2].tunnel?.publicURL == "https://demo.trycloudflare.com")
        #expect(open[3].publicURL == "https://demo.trycloudflare.com")
        _ = cache.apply([agent, vite, cf, other], probe: true)
        #expect(log.all.sorted() == ["20241/quicktunnel", "4040/api/tunnels"])   // cached per agent instance
        let reversed = cache.apply([vite], probe: false, reverse: [3000: "Reachable on demo :8080 (ssh -R)"])
        #expect(reversed[0].exposedVia == "Reachable on demo :8080 (ssh -R)")
    }

    @Test("Loopback HTTP client fetches a local API")
    func loopback() throws {
        let s = try TestListener()
        s.serve(Array("HTTP/1.1 200 OK\r\nContent-Length: 14\r\n\r\n{\"tunnels\":[]}".utf8))
        let r = try #require(loopbackHTTP(port: s.port, path: "/api/tunnels", timeout: 5))
        #expect(r.status == 200 && r.body == Data(#"{"tunnels":[]}"#.utf8))
        #expect(loopbackHTTP(port: s.port, path: "/a b") == nil)
        #expect(loopbackHTTP(port: 0, path: "/") == nil)
    }
}
