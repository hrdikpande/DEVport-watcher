import Darwin
import Foundation

// MARK: - Web probe (menu open only; loopback addresses only; < 1 s per listener; read-only)

public enum WebScheme: String, Sendable { case http, https }

/// Decide from a server's first bytes whether it speaks HTTP, HTTPS, or neither.
public func webScheme(fromReply b: [UInt8]) -> WebScheme? {
    if b.starts(with: Array("HTTP/".utf8)) {
        let text = String(decoding: b, as: UTF8.self).lowercased()   // nginx: "plain HTTP request was sent to HTTPS port"
        return text.contains("https port") || text.contains("speak https") ? .https : .http
    }
    if b.count >= 2, b[0] == 0x15 || b[0] == 0x16, b[1] == 0x03 { return .https }   // TLS alert / handshake record
    return nil
}

let httpProbe = Array("HEAD / HTTP/1.0\r\nHost: localhost\r\nUser-Agent: Ports\r\n\r\n".utf8)
/// Minimal TLS 1.2 ClientHello. Any TLS server answers with a handshake (0x16) or an alert (0x15).
let tlsProbe: [UInt8] = [0x16, 0x03, 0x01, 0x00, 0x33,                  // record: handshake, 51 bytes
                         0x01, 0x00, 0x00, 0x2f, 0x03, 0x03]            // ClientHello, 47 bytes, TLS 1.2
    + [UInt8](repeating: 0x2a, count: 32)                               // random
    + [0x00, 0x00, 0x06, 0xc0, 0x2f, 0x00, 0x9c, 0x00, 0x2f,            // no session; 3 cipher suites
       0x01, 0x00, 0x00, 0x00]                                          // null compression; no extensions

/// Send `payload`, return the first bytes of the reply ([] if none), or nil if we couldn't connect.
/// Loopback only, by construction: any other host is refused before a socket is opened.
func exchange(host: String, port: Int, payload: [UInt8], deadline: Date) -> [UInt8]? {
    guard host == "127.0.0.1" || host == "::1" else { return nil }
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return nil }
    defer { freeaddrinfo(res) }
    let fd = socket(ai.pointee.ai_family, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    func ms() -> Int32 { Int32(max(0, deadline.timeIntervalSinceNow) * 1000) }
    if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) != 0 {
        guard errno == EINPROGRESS else { return nil }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var err: Int32 = 0, len = socklen_t(MemoryLayout<Int32>.size)
        guard poll(&p, 1, ms()) == 1, getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { return nil }
    }
    guard payload.withUnsafeBytes({ send(fd, $0.baseAddress, payload.count, 0) }) == payload.count else { return [] }
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&p, 1, ms()) == 1 else { return [] }
    var buf = [UInt8](repeating: 0, count: 512)
    let n = recv(fd, &buf, buf.count, 0)
    return n > 0 ? Array(buf.prefix(n)) : []
}

/// Worth probing: dev servers and published container ports that answer on loopback.
/// Never Databases-kind, system or suspended processes, and never a non-loopback address.
public func isWebCandidate(_ l: Listener) -> Bool {
    if case .specific = l.exposure { return false }       // bound to a LAN address only: not reachable on loopback
    // Never a database: by process, by container image, or found by a handshake.
    if knownDatabase(l) != nil { return false }
    return !l.stopped && l.baseKind != .database && (l.container != nil || l.baseKind == .frontend || l.baseKind == .backend)
}

public let webProbeBudget: TimeInterval = 0.8             // whole probe of one listener, all attempts included

/// Plain HTTP first; if the server says nothing, try a TLS hello. Loopback only, within `webProbeBudget`.
/// `budget` is injectable for tests whose test server may answer slowly under load; production uses the default.
public func probeWeb(_ l: Listener, budget: TimeInterval = webProbeBudget) -> WebScheme? {
    guard isWebCandidate(l) else { return nil }
    let deadline = Date().addingTimeInterval(budget)
    for host in ["127.0.0.1", "::1"] {
        guard let reply = exchange(host: host, port: l.port, payload: httpProbe, deadline: deadline) else { continue }
        if let scheme = webScheme(fromReply: reply) { return scheme }
        guard reply.isEmpty else { return nil }                 // spoke, but not HTTP or TLS
        let tls = exchange(host: host, port: l.port, payload: tlsProbe, deadline: deadline) ?? []
        return webScheme(fromReply: tls) == .https ? .https : nil
    }
    return nil
}

public func browserURL(_ l: Listener, _ scheme: WebScheme) -> URL? {
    var host = "localhost"
    if case .specific(let ip) = l.exposure { host = ip.contains(":") ? "[\(ip)]" : ip }
    return URL(string: "\(scheme.rawValue)://\(host):\(l.port)")
}
