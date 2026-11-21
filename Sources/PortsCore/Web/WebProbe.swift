// Phase 9: web probe details — status, response time, Server header and <title> (first 64 KB).
// Panel open only, loopback only (127.0.0.1 / ::1), 0.8 s per listener, at most 4 at once, cached 30 s,
// read-only (one GET /). Self-signed TLS certificates are accepted for this probe only.
import Darwin
import Foundation
import Network

public struct WebInfo: Equatable, Sendable {
    public let scheme: WebScheme
    public let status: Int?
    public let ms: Int?
    public let server: String?
    public let title: String?
    public let isJSON: Bool
    /// "200 · 34 ms · My App"
    public var summary: String {
        [status.map(String.init), ms.map { "\($0) ms" }, title].compactMap { $0 }.joined(separator: " · ")
    }
}

let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]

/// The page `<title>` from the first 64 KB: entities decoded, whitespace collapsed, at most 80 characters.
public func htmlTitle(_ body: Data) -> String? {
    let text = String(decoding: body.prefix(65_536), as: UTF8.self)
    guard let open = text.range(of: #"<title[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
          let close = text.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<text.endIndex) else { return nil }
    var t = String(text[open.upperBound..<close.lowerBound])
    for (k, v) in entities { t = t.replacingOccurrences(of: k, with: v) }
    while let m = t.range(of: #"&#(\d{1,6});"#, options: .regularExpression) {
        let code = UInt32(t[m].dropFirst(2).dropLast()) ?? 63
        t.replaceSubrange(m, with: String(UnicodeScalar(code).map(Character.init) ?? "?"))
    }
    t = t.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    guard !t.isEmpty else { return nil }
    return t.count > 80 ? String(t.prefix(79)) + "…" : t
}

/// JSON API: a JSON content type, or a body that starts like JSON.
public func looksJSON(contentType: String?, body: Data) -> Bool {
    if let ct = contentType?.lowercased(), ct.contains("json") { return true }
    let first = String(decoding: body.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).first
    return first == "{" || first == "["
}

func connectLoopback(_ host: String, port: Int, deadline: Date) -> Int32? {
    guard host == "127.0.0.1" || host == "::1" else { return nil }              // loopback only, by construction
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return nil }
    defer { freeaddrinfo(res) }
    let fd = socket(ai.pointee.ai_family, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) != 0 {
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var err: Int32 = 0, len = socklen_t(MemoryLayout<Int32>.size)
        guard errno == EINPROGRESS, poll(&p, 1, Int32(max(0, deadline.timeIntervalSinceNow) * 1000)) == 1,
              getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { close(fd); return nil }
    }
    return fd
}

/// Plain-HTTP GET / on loopback, reading at most 64 KB.
func plainGet(port: Int, deadline: Date) -> HTTPResponse? {
    for host in ["127.0.0.1", "::1"] {
        guard let fd = connectLoopback(host, port: port, deadline: deadline) else { continue }
        defer { close(fd) }
        return exchangeHTTP(fd: fd, method: "GET", path: "/", host: "localhost:\(port)", deadline: deadline, maxBytes: 65_536)
    }
    return nil
}

/// HTTPS GET / on loopback via Network.framework; any certificate is accepted (probe only, nothing sent but the GET).
func tlsGet(port: Int, deadline: Date) -> HTTPResponse? {
    guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
    let queue = DispatchQueue(label: "ports.tls-probe")
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
    let conn = NWConnection(host: "127.0.0.1", port: p, using: NWParameters(tls: tls))
    final class Box: @unchecked Sendable { var data = Data(); var done = false }
    let box = Box(), finished = DispatchSemaphore(value: 0)
    func finish() { queue.async { if !box.done { box.done = true; finished.signal() } } }
    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, complete, error in
            if let chunk { box.data.append(chunk) }
            if complete || error != nil || box.data.count >= 65_536 || completeResponse(box.data) != nil { finish() } else { receive() }
        }
    }
    conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
            let req = "GET / HTTP/1.1\r\nHost: localhost:\(port)\r\nUser-Agent: \(Brand.displayName)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in receive() })
        case .failed, .cancelled: finish()
        default: break
        }
    }
    conn.start(queue: queue)
    _ = finished.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
    conn.cancel()
    return queue.sync { completeResponse(box.data) ?? parseHTTPHead(box.data) }
}

/// Scheme first (Phase 1 probe), then one GET for the details, all within `budget`.
public func probeWebInfo(_ l: Listener, budget: TimeInterval = webProbeBudget) -> WebInfo? {
    guard isWebCandidate(l) else { return nil }
    let deadline = Date().addingTimeInterval(budget)
    guard let scheme = probeWeb(l, budget: budget) else { return nil }
    let start = Date()
    let r = scheme == .https ? tlsGet(port: l.port, deadline: deadline) : plainGet(port: l.port, deadline: deadline)
    guard let r else { return WebInfo(scheme: scheme, status: nil, ms: nil, server: nil, title: nil, isJSON: false) }
    return WebInfo(scheme: scheme, status: r.status, ms: Int(Date().timeIntervalSince(start) * 1000),
                   server: r.header("Server"), title: htmlTitle(r.body), isJSON: looksJSON(contentType: r.header("Content-Type"), body: r.body))
}

/// Run `body` over `items` with at most `limit` running at once; results keep their order.
final class BoundedResults<R>: @unchecked Sendable {
    var values: [R?]
    let lock = NSLock()
    var next = 0
    init(_ n: Int) { values = Array(repeating: nil, count: n) }
}

public func boundedMap<T: Sendable, R: Sendable>(_ items: [T], limit: Int, _ body: @Sendable (T) -> R) -> [R] {
    let box = BoundedResults<R>(items.count)
    DispatchQueue.concurrentPerform(iterations: min(max(1, limit), max(1, items.count))) { _ in
        while true {
            box.lock.lock(); let i = box.next; box.next += 1; box.lock.unlock()
            guard i < items.count else { return }
            let r = body(items[i])
            box.lock.lock(); box.values[i] = r; box.lock.unlock()
        }
    }
    return box.values.map { $0! }
}

/// Probe results per listener instance, re-probed after `maxAge` (30 s) while the panel stays open. Thread-safe.
public final class WebProbeCache: @unchecked Sendable {
    public static let shared = WebProbeCache()
    private let lock = NSLock()
    private var known: [String: (info: WebInfo?, at: Date)] = [:]
    private let probe: @Sendable (Listener) -> WebInfo?
    public let maxAge: TimeInterval
    public init(maxAge: TimeInterval = 30, probe: @escaping @Sendable (Listener) -> WebInfo? = { probeWebInfo($0) }) {
        self.maxAge = maxAge
        self.probe = probe
    }

    public func apply(_ ls: [Listener], probe doProbe: Bool, now: Date = Date()) -> [Listener] {
        if doProbe {
            lock.lock()
            let todo = ls.filter { l in isWebCandidate(l) && (known[listenerKey(l)].map { now.timeIntervalSince($0.at) >= maxAge } ?? true) }
            lock.unlock()
            let found = boundedMap(todo, limit: 4, probe)
            lock.lock(); for (l, w) in zip(todo, found) { known[listenerKey(l)] = (w, now) }; lock.unlock()
        }
        lock.lock(); defer { lock.unlock() }
        let live = Set(ls.map(listenerKey))
        known = known.filter { live.contains($0.key) }
        return ls.map { l in
            var r = l
            if let w = known[listenerKey(l)]?.info { r.webInfo = w; r.web = w.scheme }
            return r
        }
    }
}

// MARK: - Addresses, QR target, hints, search

/// The Mac's current LAN IPv4 address (first active en* interface).
public func lanAddress() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return nil }
    defer { freeifaddrs(head) }
    var p = head
    var found: String?
    while let i = p {
        defer { p = i.pointee.ifa_next }
        let name = String(cString: i.pointee.ifa_name)
        guard name.hasPrefix("en"), let sa = i.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
              i.pointee.ifa_flags & UInt32(IFF_UP) != 0, i.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        let ip = ntop(AF_INET, addr)
        if !ip.hasPrefix("169.254.") { found = found ?? ip }
    }
    return found
}

public func hostPort(_ l: Listener) -> String {
    if case .specific(let ip) = l.exposure { return ip.contains(":") ? "[\(ip)]:\(l.port)" : "\(ip):\(l.port)" }
    return "localhost:\(l.port)"
}

/// For a network-reachable server: the URL a phone on the same network opens. nil when loopback-only.
public func lanURL(_ l: Listener, lanIP: String? = lanAddress()) -> URL? {
    let scheme = (l.web ?? .http).rawValue
    switch l.exposure {
    case .loopback: return nil
    case .specific(let ip): return URL(string: "\(scheme)://\(ip.contains(":") ? "[\(ip)]" : ip):\(l.port)")
    case .allInterfaces: return lanIP.flatMap { URL(string: "\(scheme)://\($0):\(l.port)") }
    }
}

/// How to make a loopback-only dev server reachable from a phone, per framework.
public func exposeHint(_ l: Listener) -> String {
    let hint: [String: String] = ["Vite": "vite --host", "Astro": "astro dev --host", "Next.js": "next dev -H 0.0.0.0",
                                  "Nuxt": "nuxi dev --host", "SvelteKit": "vite dev --host", "Webpack dev server": "webpack serve --host 0.0.0.0",
                                  "Angular CLI": "ng serve --host 0.0.0.0", "Django": "manage.py runserver 0.0.0.0:\(l.port)",
                                  "Flask": "flask run --host 0.0.0.0", "Rails": "rails server -b 0.0.0.0", "Uvicorn": "uvicorn … --host 0.0.0.0",
                                  "Expo": "expo start --lan", "Hugo": "hugo server --bind 0.0.0.0", "Jekyll": "jekyll serve --host 0.0.0.0"]
    let cmd = l.framework.flatMap { hint[$0] }.map { "`\($0)`" } ?? "its host/bind option (0.0.0.0)"
    return "It listens on loopback only, so other devices can't reach it. Start it with \(cmd) to test from a phone on your network."
}

/// A web search for an unknown port/process: port and process name only, never paths or arguments.
public func webSearchURL(_ l: Listener) -> URL? {
    let what = l.framework ?? appName(l.exe)
    var c = URLComponents(string: "https://duckduckgo.com/")
    c?.queryItems = [URLQueryItem(name: "q", value: "macOS port \(l.port) \(what)")]
    return c?.url
}
