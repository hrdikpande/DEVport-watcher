// Phase 6: a small HTTP/1.1 client for the Docker Engine API over a unix socket. Read-only except
// container stop/restart; 2 s timeout by default; responses capped at 8 MB.
import Darwin
import Foundation

public struct HTTPResponse: Equatable, Sendable {
    public let status: Int
    public let body: Data
}

/// Parse a complete HTTP/1.x response (Content-Length, chunked, or read-to-close).
public func parseHTTPResponse(_ raw: Data) -> HTTPResponse? {
    guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: raw[..<sep.lowerBound], as: UTF8.self)
    let lines = head.components(separatedBy: "\r\n")
    let parts = lines.first?.split(separator: " ") ?? []
    guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else { return nil }
    var headers: [String: String] = [:]
    for l in lines.dropFirst() {
        guard let c = l.firstIndex(of: ":") else { continue }
        headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
    }
    var body = Data(raw[sep.upperBound...])
    if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
        var out = Data(), rest = body[...]
        while let lineEnd = rest.range(of: Data("\r\n".utf8)) {
            let sizeText = String(decoding: rest[..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            if size == 0 { break }
            let start = lineEnd.upperBound
            guard rest.distance(from: start, to: rest.endIndex) >= size else { return nil }   // truncated
            let end = rest.index(start, offsetBy: size)
            out.append(rest[start..<end])
            rest = rest[end...].dropFirst(2)
        }
        body = out
    } else if let len = headers["content-length"].flatMap(Int.init) {
        guard body.count >= len else { return nil }
        body = body.prefix(len)
    }
    return HTTPResponse(status: status, body: body)
}

/// One request over a unix socket with `Connection: close`; nil on any failure or timeout.
public func unixHTTP(socket path: String, method: String = "GET", path request: String,
                     timeout: TimeInterval = 2) -> HTTPResponse? {
    guard path.utf8.count < 104, request.hasPrefix("/"), !request.contains(" "), !request.contains("\r") else { return nil }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in path.utf8.enumerated() { buf[i] = b }
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let deadline = Date().addingTimeInterval(timeout)
    func ms() -> Int32 { Int32(max(0, deadline.timeIntervalSinceNow) * 1000) }
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if r != 0 {
        guard errno == EINPROGRESS || errno == EAGAIN else { return nil }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var err: Int32 = 0, len = socklen_t(MemoryLayout<Int32>.size)
        guard poll(&p, 1, ms()) == 1, getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { return nil }
    }
    let req = Array("\(method) \(request) HTTP/1.1\r\nHost: docker\r\nUser-Agent: \(Brand.displayName)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    var sent = 0
    while sent < req.count {
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, ms()) == 1 else { return nil }
        let n = req[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard n > 0 else { return nil }
        sent += n
    }
    var data = Data(), buf = [UInt8](repeating: 0, count: 65536)
    while data.count < 8_000_000 {
        if let done = completeResponse(data) { return done }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, ms()) == 1 else { return nil }
        let n = recv(fd, &buf, buf.count, 0)
        if n <= 0 { return parseHTTPResponse(data) }      // closed: a close-delimited body ends here
        data.append(contentsOf: buf.prefix(n))
    }
    return nil
}

/// A response whose declared body has fully arrived (Content-Length reached, last chunk seen,
/// or a status without a body); nil while more is expected.
func completeResponse(_ data: Data) -> HTTPResponse? {
    guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self).lowercased()
    let status = head.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
    if status == 204 || status == 304 { return parseHTTPResponse(data) }
    if head.contains("transfer-encoding: chunked") {
        return data.suffix(5) == Data("0\r\n\r\n".utf8) ? parseHTTPResponse(data) : nil
    }
    if head.contains("content-length:") { return parseHTTPResponse(data) }   // nil until the body is complete
    return nil
}

// MARK: - Containers

public struct PublishedPort: Equatable, Sendable {
    public let ip: String           // "0.0.0.0", "127.0.0.1", "::", "" (all interfaces)
    public let privatePort: Int
    public let publicPort: Int
    public let proto: String
    public var allInterfaces: Bool { ip.isEmpty || ip == "0.0.0.0" || ip == "::" }
}

public struct ContainerInfo: Equatable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let state: String        // running, exited, …
    public let status: String       // "Up 2 hours (healthy)"
    public let project: String?     // com.docker.compose.project
    public let service: String?     // com.docker.compose.service
    public let ports: [PublishedPort]
    public let runtime: ContainerRuntime?

    /// healthy / unhealthy / starting, from the status text.
    public var health: String? {
        let s = status.lowercased()
        if s.contains("(healthy)") { return "healthy" }
        if s.contains("(unhealthy)") { return "unhealthy" }
        if s.contains("health: starting") { return "starting" }
        return nil
    }
    /// "web-1 · postgres:16 · shop/db · healthy"
    public var label: String {
        var parts = [name, image]
        if let p = project { parts.append(service.map { "\(p)/\($0)" } ?? p) }
        if let h = health { parts.append(h) }
        return parts.joined(separator: " · ")
    }
    public func publishedOnAllInterfaces(_ port: Int) -> Bool {
        ports.contains { $0.publicPort == port && $0.allInterfaces }
    }
}

/// `GET /containers/json` -> containers.
public func parseContainers(_ json: Data, runtime: ContainerRuntime? = nil) -> [ContainerInfo] {
    guard let rows = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
    return rows.compactMap { r in
        guard let id = r["Id"] as? String, id.range(of: "^[0-9a-f]{12,64}$", options: .regularExpression) != nil else { return nil }
        let name = ((r["Names"] as? [String])?.first ?? id.prefix(12).description).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let labels = r["Labels"] as? [String: String] ?? [:]
        let ports = (r["Ports"] as? [[String: Any]] ?? []).compactMap { p -> PublishedPort? in
            guard let pub = p["PublicPort"] as? Int else { return nil }
            return PublishedPort(ip: p["IP"] as? String ?? "", privatePort: p["PrivatePort"] as? Int ?? 0,
                                 publicPort: pub, proto: p["Type"] as? String ?? "tcp")
        }
        return ContainerInfo(id: id, name: name, image: r["Image"] as? String ?? "", state: r["State"] as? String ?? "",
                             status: r["Status"] as? String ?? "", project: labels["com.docker.compose.project"],
                             service: labels["com.docker.compose.service"], ports: ports, runtime: runtime)
    }
}

public enum EngineError: Error, Equatable, CustomStringConvertible {
    case unreachable, refused(String), http(Int, String)
    public var description: String {
        switch self {
        case .unreachable: "The container engine didn't answer."
        case .refused(let s): s
        case .http(let code, let body): "The engine answered \(code): \(body)"
        }
    }
}

/// POST /containers/<id>/<stop|restart>?t=10. 204 = done, 304 = already in that state.
public func engineContainerAction(_ action: String, id: String, socket: String, timeout: TimeInterval = 25) -> EngineError? {
    guard ["stop", "restart"].contains(action), id.range(of: "^[0-9a-f]{12,64}$", options: .regularExpression) != nil else {
        return .refused("Unsafe container id or action.")
    }
    guard let r = unixHTTP(socket: socket, method: "POST", path: "/containers/\(id)/\(action)?t=10", timeout: timeout) else {
        return .unreachable
    }
    return [204, 304].contains(r.status) ? nil : .http(r.status, String(decoding: r.body.prefix(300), as: UTF8.self))
}

/// The container's restart policy (`GET /containers/<id>/json`), e.g. "unless-stopped"; nil if unknown.
public func engineRestartPolicy(id: String, socket: String) -> String? {
    guard id.range(of: "^[0-9a-f]{12,64}$", options: .regularExpression) != nil,
          let r = unixHTTP(socket: socket, path: "/containers/\(id)/json"), r.status == 200,
          let json = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
          let policy = ((json["HostConfig"] as? [String: Any])?["RestartPolicy"] as? [String: Any])?["Name"] as? String
    else { return nil }
    return policy.isEmpty ? "no" : policy
}
