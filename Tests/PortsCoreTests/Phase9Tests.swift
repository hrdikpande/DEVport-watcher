import Darwin
import Foundation
import Testing
@testable import PortsCore

func webRow(port: Int, kind: Kind = .frontend, exposure: Exposure = .loopback, framework: String? = "Vite") -> Listener {
    var l = Listener(port: port, pid: getpid(), start: 1, uid: getuid(), exposed: exposure.isNetworkReachable, exposure: exposure,
                     exe: "/usr/local/bin/vite", command: "vite", argv: ["vite"], cwd: "/tmp/demo", kind: kind)
    l.framework = framework
    return l
}

final class Counter9: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0, active = 0, peak = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    func enter() { lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
    func leave() { lock.lock(); active -= 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    var maxActive: Int { lock.lock(); defer { lock.unlock() }; return peak }
}

@Suite("Phase 9 · Page details")
struct PageDetailTests {
    static let titles: [(String, String?)] = [
        ("<html><head><title>My App</title></head>", "My App"),
        ("<TITLE lang=\"en\">Shop &amp; Co</TITLE>", "Shop & Co"),
        ("<title>\n   Admin\n   Panel  </title>", "Admin Panel"),
        ("<title>caf&#233; &lt;3</title>", "café <3"),
        ("<title></title>", nil),
        ("<h1>No title</h1>", nil),
        ("<title>" + String(repeating: "x", count: 100) + "</title>", String(repeating: "x", count: 79) + "…"),
        (String(repeating: " ", count: 70_000) + "<title>Too late</title>", nil),
    ]
    @Test("<title> from the first 64 KB", arguments: titles)
    func title(html: String, expected: String?) { #expect(htmlTitle(Data(html.utf8)) == expected) }

    @Test("JSON API detection", arguments: [
        ("application/json; charset=utf-8", "", true), ("application/problem+json", "", true), (nil, "  {\"a\":1}", true),
        (nil, "[1,2]", true), ("text/html", "<html>", false), (nil, "OK", false),
    ] as [(String?, String, Bool)])
    func json(ct: String?, body: String, expected: Bool) { #expect(looksJSON(contentType: ct, body: Data(body.utf8)) == expected) }

    @Test("Row summary: status · time · title")
    func summary() {
        #expect(WebInfo(scheme: .http, status: 200, ms: 34, server: nil, title: "My App", isJSON: false).summary == "200 · 34 ms · My App")
        #expect(WebInfo(scheme: .https, status: nil, ms: nil, server: nil, title: nil, isJSON: false).summary.isEmpty)
    }

    @Test("A real loopback page: status, time, server header and title; a JSON API gets the badge")
    func realPage() throws {
        let page = try TestListener()
        let html = "<html><title>Demo Page</title></html>"
        page.serve(Array("HTTP/1.1 200 OK\r\nServer: demo/1.0\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)".utf8))
        let info = try #require(probeWebInfo(webRow(port: page.port), budget: 10))
        #expect(info.scheme == .http && info.status == 200 && info.title == "Demo Page" && info.server == "demo/1.0" && !info.isJSON)
        #expect(info.ms != nil)
        let api = try TestListener()
        api.serve(Array("HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8))
        let j = try #require(probeWebInfo(webRow(port: api.port, kind: .backend), budget: 10))
        #expect(j.status == 404 && j.isJSON)
    }

    @Test("Never probed: databases, LAN-only binds, tunnels; a TLS GET to a plain server fails within its deadline")
    func neverProbed() throws {
        let s = try TestListener()
        s.serve(Array("HTTP/1.1 200 OK\r\n\r\n".utf8))
        #expect(probeWebInfo(webRow(port: s.port, kind: .database)) == nil)
        #expect(probeWebInfo(webRow(port: s.port, exposure: .specific("192.168.1.20"))) == nil)
        #expect(probeWebInfo(webRow(port: s.port, kind: .tunnel)) == nil)
        let t0 = Date()
        #expect(tlsGet(port: s.port, deadline: t0.addingTimeInterval(0.5))?.status == nil)
        #expect(Date().timeIntervalSince(t0) < 2 * 0.5 + 1)
    }
}

@Suite("Phase 9 · Probe scheduling")
struct ProbeSchedulingTests {
    @Test("At most N probes run at once, and results keep their order")
    func bounded() {
        let c = Counter9()
        let out = boundedMap(Array(0..<40), limit: 4) { i -> Int in c.enter(); defer { c.leave() }; return i * 2 }
        #expect(out == Array(0..<40).map { $0 * 2 })
        #expect(c.maxActive <= 4)
        #expect(boundedMap([Int](), limit: 4) { $0 }.isEmpty)
    }

    @Test("Probed only when asked, re-probed after 30 s, pruned when gone")
    func cache() {
        let calls = Counter9()
        let cache = WebProbeCache(maxAge: 30, probe: { _ in calls.bump(); return WebInfo(scheme: .http, status: 200, ms: 1, server: nil, title: "T", isJSON: false) })
        let l = webRow(port: 3000)
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(cache.apply([l], probe: false, now: t0)[0].webInfo == nil)
        #expect(calls.value == 0)                                                // menu closed: never
        #expect(cache.apply([l], probe: true, now: t0)[0].webInfo?.title == "T")
        _ = cache.apply([l], probe: true, now: t0.addingTimeInterval(29))
        #expect(calls.value == 1)                                                // cached
        _ = cache.apply([l], probe: true, now: t0.addingTimeInterval(31))
        #expect(calls.value == 2)                                                // 30 s later: again
        #expect(cache.apply([l], probe: false, now: t0)[0].web == .http)
        _ = cache.apply([], probe: false, now: t0)
        #expect(cache.apply([l], probe: false, now: t0)[0].webInfo == nil)       // pruned
    }
}

@Suite("Phase 9 · LAN URL, hints, search")
struct LanTests {
    @Test("LAN URL only for network-reachable servers")
    func lan() {
        #expect(lanURL(webRow(port: 5173), lanIP: "192.168.1.20") == nil)
        #expect(lanURL(webRow(port: 5173, exposure: .allInterfaces), lanIP: "192.168.1.20")?.absoluteString == "http://192.168.1.20:5173")
        var tls = webRow(port: 8443, exposure: .specific("192.168.1.30")); tls.web = .https
        #expect(lanURL(tls, lanIP: nil)?.absoluteString == "https://192.168.1.30:8443")
        #expect(lanURL(webRow(port: 1, exposure: .allInterfaces), lanIP: nil) == nil)
        #expect(hostPort(webRow(port: 5173)) == "localhost:5173")
        #expect(hostPort(webRow(port: 80, exposure: .specific("fe80::1"))) == "[fe80::1]:80")
    }

    @Test("How to expose a loopback-only server, per framework")
    func hints() {
        #expect(exposeHint(webRow(port: 5173)).contains("`vite --host`"))
        #expect(exposeHint(webRow(port: 8000, framework: "Django")).contains("runserver 0.0.0.0:8000"))
        #expect(exposeHint(webRow(port: 9, framework: nil)).contains("0.0.0.0"))
    }

    @Test("Web search uses the port and process name only, never paths")
    func search() throws {
        var l = Listener(port: 7777, pid: 1, start: 1, uid: getuid(), exposed: false, exe: "/Users/test/private/bin/mysteryd",
                         command: "mysteryd --token abc", cwd: "/Users/test/private")
        l.kind = .system
        let url = try #require(webSearchURL(l)).absoluteString
        #expect(url.hasPrefix("https://duckduckgo.com/?q="))
        #expect(url.contains("7777") && url.contains("mysteryd"))
        #expect(!url.contains("Users") && !url.contains("private") && !url.contains("token"))
    }
}
